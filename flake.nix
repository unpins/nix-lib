{
  description = "Shared Nix helpers for unpins/* packages";

  # Bundled so consumers don't redeclare; bump propagates to every unpins/*.
  # Override via `inputs.unpins-lib.inputs.nixpkgs.follows = "nixpkgs"`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      lib = rec {
        # Canonical native targets. Editing here propagates to every unpins/* consumer.
        # forAllNative is pure nix (no nixpkgs.lib dep) so nix-lib stays standalone.
        nativeSystems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];

        forAllNative = f:
          builtins.listToAttrs
            (map (sys: { name = sys; value = f sys; }) nativeSystems);

        # Remove .so/.dylib/.la/.dll/.dll.a from a drv's outputs; leave .a + headers + bins.
        # Build-system agnostic (postFixup, not configure flags).
        #
        # Why: GNU ld and Apple ld64 both prefer shared over .a in -L paths, and ld64 has
        # no `-Bstatic` analog. Removing the shared artifact post-build is the only
        # platform-neutral way to force a static link without patching the consumer.
        #
        # Self-guarded: pkgsStatic drvs already produce only .a; skip them to avoid busting
        # cache.nixos.org without changing the output.
        dropSharedLibs = drv:
          let isStatic = drv.stdenv.hostPlatform.isStatic or false;
          in if isStatic then drv
          else drv.overrideAttrs (old: {
            postFixup = (old.postFixup or "") + ''
              for o in $outputs; do
                d="''${!o}"
                [ -d "$d/lib" ] || continue
                find "$d/lib" \( \
                       -name '*.dylib' -o -name '*.dylib.*' \
                    -o -name '*.so'    -o -name '*.so.*'    \
                    -o -name '*.la'                          \
                    -o -name '*.dll'   -o -name '*.dll.a'    \
                  \) -delete 2>/dev/null || true
              done
            '';
          });

        # Embed an UNPIN_META alias block into `$out/bin/<primary>` so unpin's
        # installer can spawn argv[0]-dispatch links (xz → xzcat/unxz/lzma…) at
        # `unpin install` time. The block is a payload bracketed by 0xff-0xff
        # sentinels (see unpin/src/aliases.rs) and the reader scans for the
        # sentinels in the file bytes — section name is irrelevant to consumption.
        #
        # We write into a custom `.unpin_meta` section via
        # `llvm-objcopy --add-section` (not append-after-EOF) for three reasons:
        # (1) ELF/PE/Mach-O all accept a named SHT_PROGBITS section and
        # llvm-objcopy adjusts the headers correctly across formats;
        # (2) standard `strip` only removes debug/symbol sections by name, so
        # `.unpin_meta` survives — a trailer would be lost by any tool that
        # rewrites the file by declared image size; (3) future code-signing
        # puts the section inside the signature envelope while a trailer
        # would invalidate it. `noload` + no `SHF_ALLOC` means the section is
        # a file-only artifact — zero runtime memory cost.
        #
        # NB: we deliberately AVOID the `.note.*` namespace. llvm-objcopy
        # parses `.note.*` payloads as structured ELF note records (namesz +
        # descsz + type + payload), enforces 4-byte alignment, and rejects raw
        # bytes that don't fit the schema. SHT_PROGBITS with a non-`.note`
        # name dodges that entirely.
        #
        # Two input modes (exactly one required):
        #   aliases = [ "xzcat" "unxz" "lzma" ];   # explicit list, Nix-eval-time
        #   aliasesFromSymlinksIn = "bin";         # harvest $out/bin/* symlinks
        #
        # `aliasesFromSymlinksIn` is the multicall pattern (coreutils,
        # busybox): upstream creates one symlink per applet next to the real
        # multicall binary. We collect them in postInstall, wipe the symlinks
        # (we ship one binary, the alias links are unpin's job at install time)
        # then embed the list in postFixup so the embed runs AFTER stdenv strip.
        #
        # Cosmocc / APE binaries: cosmocc emits PE-at-head + ZIP-at-tail. Naïve
        # `llvm-objcopy` would parse only the PE half and silently drop the
        # tail ZIP (losing `.symtab.amd64` and any embedded runtime resources).
        # The embed step auto-detects the tail-ZIP case via `unzip -l` and
        # picks the safe path:
        #
        #   (a) ZIP contains only debug/marker entries (`.symtab.*`, `.cosmo`):
        #       truncate the ZIP entirely so the artifact is a pure PE/ELF/
        #       Mach-O, then `llvm-objcopy --add-section`. Saves ~80–230 KB
        #       per artifact by dropping debug symtab — affects crash-time
        #       stack symbolication only, runtime behavior unaffected.
        #
        #   (b) ZIP carries functional data (e.g. `usr/share/zoneinfo/*` for
        #       bash/coreutils on Windows where no system zoneinfo exists):
        #       append our meta as a *stored* (not deflated) ZIP entry. The
        #       0xff-0xff sentinels appear verbatim in the entry payload, so
        #       the unpin scanner finds them; cosmocc's `/zip/<name>` lookups
        #       are by name and our new entry doesn't conflict.
        #
        # Non-ZIP binaries (every native build, mingw cross): single branch
        # straight to `llvm-objcopy`. No new dependencies along the hot path.
        withAliases = pkgs:
          { primary
          , aliases ? null
          , aliasesFromSymlinksIn ? null
          }: drv:
          let
            hasExplicit = aliases != null;
            hasAuto = aliasesFromSymlinksIn != null;

            # Mirrors `validate_alias` in unpin/src/aliases.rs so a bogus
            # name fails the build instead of the install. Kept in sync
            # by hand — the Rust function is the canonical reference.
            unpinBlockedNames = [
              "sudo" "su" "doas" "ssh" "scp" "sftp"
              "ssh-add" "ssh-agent" "ssh-keygen"
              "git" "gh" "hg" "svn"
              "gpg" "gpg2" "pinentry" "age" "rage"
              "python" "python2" "python3" "node" "nodejs" "deno"
              "npm" "npx" "yarn" "pnpm"
              "cargo" "rustc" "rustup" "go" "java" "javac"
              "ruby" "gem" "bundle" "perl" "php" "lua"
              "bash" "sh" "zsh" "fish" "ksh" "dash" "csh" "tcsh"
              "cmd" "powershell" "pwsh"
              "unpin"
            ];
            unpinWindowsReserved = [
              "CON" "PRN" "AUX" "NUL"
              "COM1" "COM2" "COM3" "COM4" "COM5"
              "COM6" "COM7" "COM8" "COM9"
              "LPT1" "LPT2" "LPT3" "LPT4" "LPT5"
              "LPT6" "LPT7" "LPT8" "LPT9"
            ];
            validateAliasName = name:
              let
                lib_ = nixpkgs.lib;
                chars = lib_.stringToCharacters name;
                isAlnum = c: builtins.match "[a-z0-9]" c != null;
                isAllowed = c: builtins.match "[a-z0-9._-]" c != null;
                stem = builtins.head (lib_.splitString "." name);
              in
              if name == "" then
                throw "withAliases: empty alias name"
              else if lib_.stringLength name > 64 then
                throw "withAliases: alias `${name}` length ${toString (lib_.stringLength name)} exceeds 64"
              else if !(isAlnum (builtins.head chars)) then
                throw "withAliases: alias `${name}` must start with [a-z0-9]"
              else if builtins.any (c: !(isAllowed c)) chars then
                throw "withAliases: alias `${name}` has char outside [a-z0-9._-]"
              else if builtins.elem (lib_.toUpper stem) unpinWindowsReserved then
                throw "withAliases: alias `${name}` matches a Windows reserved device name"
              else if builtins.elem name unpinBlockedNames then
                throw "withAliases: alias `${name}` would shadow a sensitive command (blocklist)"
              else name;

            # Force validation by mapping validate over the list before
            # concatenating. concatStringsSep is strict over its inputs,
            # so every name is exercised at eval time.
            validatedAliases =
              if hasExplicit
              then builtins.map validateAliasName aliases
              else [ ];
            explicitCsv = nixpkgs.lib.concatStringsSep "," validatedAliases;

            # Shell-side blocklist — same set as unpinBlockedNames, rendered
            # for `case` glob alternation. Kept lockstep with the Nix list.
            shellBlockedPattern =
              nixpkgs.lib.concatStringsSep "|" unpinBlockedNames;

            # Pick the output the binary actually lives in. nixpkgs convention:
            # multi-output drvs put bins under the `bin` output (jq, htop in
            # some configs); pkgsStatic typically collapses to `out` even with
            # `info`/`debug` siblings (so `bin` is absent → fall back to `out`).
            # Coreutils on pkgsStatic is the latter — single binary in `$out/bin`.
            # In the inline shell snippets below, `''${${binOutputName}}` renders
            # as e.g. `${bin}` or `${out}` for bash to expand to the path.
            binOutputName =
              let outs = drv.outputs or [ "out" ];
              in
              if builtins.elem "bin" outs then "bin"
              else if builtins.elem "out" outs then "out"
              else builtins.head outs;

            wrapped = drv.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ])
                ++ [
                  pkgs.buildPackages.llvm
                  # `file` drives the per-format branch in __unpin_objcopy
                  # (Mach-O sections need __SEG,__SECT form; ELF/PE use plain
                  # names). Not in baseline stdenv on darwin.
                  pkgs.buildPackages.file
                  # unzip/zip + python3Minimal are only exercised on cosmocc
                  # outputs (tail-ZIP detection, offset compute, stored append).
                  # ~10 MB of build closure, never linked into shipped artifacts.
                  pkgs.buildPackages.unzip
                  pkgs.buildPackages.zip
                  pkgs.buildPackages.python3Minimal
                ];

              postInstall = (old.postInstall or "")
                + nixpkgs.lib.optionalString hasAuto ''
                # Mirrors validate_alias (unpin/src/aliases.rs): names that
                # the installer would reject get filtered at the source so
                # the build embeds only legal entries. Each rejection prints
                # to stderr so a surprised package author isn't left guessing
                # why their applet didn't ship as an alias.
                __unpin_aliases=""
                __unpin_count=0
                for f in "''${${binOutputName}}/${aliasesFromSymlinksIn}"/*; do
                  [ -L "$f" ] || continue
                  n="$(basename "$f")"
                  [ "$n" = "${primary}" ] && continue
                  # First char must be [a-z0-9] — coreutils' `[` lands here.
                  case "$n" in
                    [a-z0-9]*) ;;
                    *) echo "withAliases: skip '$n' (first char not [a-z0-9])" >&2; continue ;;
                  esac
                  # Every char must be in [a-z0-9._-].
                  case "$n" in
                    *[!a-z0-9._-]*) echo "withAliases: skip '$n' (char outside [a-z0-9._-])" >&2; continue ;;
                  esac
                  # Length cap (mirrors MAX_ALIAS_LEN = 64).
                  if [ "''${#n}" -gt 64 ]; then
                    echo "withAliases: skip '$n' (length ''${#n} > 64)" >&2
                    continue
                  fi
                  # Stem (chars before first dot) must not be a Windows
                  # reserved device name (matters even on Unix builds
                  # because the same package may run on Windows).
                  case "''${n%%.*}" in
                    con|prn|aux|nul|com[1-9]|lpt[1-9])
                      echo "withAliases: skip '$n' (Windows reserved device name)" >&2
                      continue
                      ;;
                  esac
                  # Blocklist (sudo/ssh/python/bash/…). Rendered from the
                  # Nix unpinBlockedNames list to stay in lockstep.
                  case "$n" in
                    ${shellBlockedPattern})
                      echo "withAliases: skip '$n' (on blocklist)" >&2
                      continue
                      ;;
                  esac
                  __unpin_aliases="''${__unpin_aliases:+$__unpin_aliases,}$n"
                  __unpin_count=$((__unpin_count + 1))
                done
                # Mirrors MAX_ALIASES = 256 in unpin/src/aliases.rs.
                if [ "$__unpin_count" -gt 256 ]; then
                  echo "withAliases: collected $__unpin_count aliases, exceeds limit of 256" >&2
                  exit 1
                fi
                printf '%s' "$__unpin_aliases" > "$NIX_BUILD_TOP/.unpin-aliases"
                find "''${${binOutputName}}/${aliasesFromSymlinksIn}" -maxdepth 1 -type l -delete
              '';

              postFixup = (old.postFixup or "") + ''
                ${if hasExplicit
                  then "__unpin_aliases='${explicitCsv}'"
                  else ''__unpin_aliases="$(cat "$NIX_BUILD_TOP/.unpin-aliases")"''}

                # Short-circuit: nothing to embed when the collected/declared
                # list ended up empty (auto-mode: no symlinks matched the
                # validator; explicit-mode: caller passed `aliases = [ ]`).
                # Avoids a 60-byte ALIASES= block that the reader would just
                # treat as no-aliases anyway.
                if [ -z "$__unpin_aliases" ]; then
                  echo "withAliases: no aliases to embed for ${primary}, skipping" >&2
                else
                  __unpin_meta="$(mktemp)"
                  # Octal escapes (\NNN) for portability — \xHH isn't POSIX,
                  # though every stdenv shell we use happens to support it.
                  # Marker bytes mirror aliases.rs MARKER_BEGIN/MARKER_END verbatim.
                  printf '\377\377UNPIN_META_v1_7f3a4e\377\377\nALIASES=%s\n\377\377UNPIN_META_END_7f3a4e\377\377\n' \
                    "$__unpin_aliases" > "$__unpin_meta"

                  __unpin_bin="''${${binOutputName}}/bin/${primary}"
                  if [ ! -f "$__unpin_bin" ]; then
                    echo "withAliases: $__unpin_bin does not exist" >&2
                    exit 1
                  fi

                  # `--remove-section` before `--add-section` keeps the embed
                  # idempotent — no-op when the section is missing, cleans up
                  # a previous embed when chained or re-run.
                  #
                  # llvm-objcopy's `--set-section-flags` is ELF-only and its
                  # section-name format differs per object format: ELF/PE
                  # accept a plain name (`.unpin_meta`), Mach-O requires
                  # `SEGNAME,SECTNAME` (`__TEXT,__unpin_meta`, both ≤ 16 chars).
                  # Branching on `file -b` keeps a single code path while
                  # respecting each format's contract. The unpin reader scans
                  # the raw file bytes for the 0xff-0xff sentinels regardless
                  # of section name, so the alias payload is found either way.
                  __unpin_objcopy() {
                    case "$(file -b "$1")" in
                      *Mach-O*)
                        llvm-objcopy \
                          --remove-section __TEXT,__unpin_meta \
                          --add-section __TEXT,__unpin_meta="$__unpin_meta" \
                          "$1"
                        ;;
                      *)
                        llvm-objcopy \
                          --remove-section .unpin_meta \
                          --add-section .unpin_meta="$__unpin_meta" \
                          --set-section-flags .unpin_meta=readonly,noload \
                          "$1"
                        ;;
                    esac
                  }

                  if unzip -l "$__unpin_bin" >/dev/null 2>&1; then
                    # Cosmocc tail-ZIP detected. Decide between purify-then-objcopy
                    # vs zip-append based on entry list.
                    __unpin_pure=1
                    while IFS= read -r __unpin_entry; do
                      case "$__unpin_entry" in
                        .symtab.*|.cosmo) ;;
                        *) __unpin_pure=0; break ;;
                      esac
                    done < <(unzip -Z1 "$__unpin_bin")

                    if [ "$__unpin_pure" = 1 ]; then
                      # ZIP only carries throwaway debug/marker. Truncate it
                      # entirely so the artifact becomes a pure PE/ELF/Mach-O.
                      # Use python's zipfile to locate the first local-file-
                      # header offset rather than `grep PK\x03\x04`, which
                      # would false-positive on coincidental matches in PE
                      # code. Crash-time symbolication is the only thing lost.
                      __unpin_offset=$(python3 -c '
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as z:
    print(min(i.header_offset for i in z.infolist()))
' "$__unpin_bin")
                      truncate -s "$__unpin_offset" "$__unpin_bin"
                      __unpin_objcopy "$__unpin_bin"
                    else
                      # ZIP has functional content (zoneinfo etc.). Append our
                      # block as a stored entry — bytes appear verbatim so the
                      # scanner finds the sentinels; -X drops uid/gid for
                      # reproducibility, and we pin the mtime via `touch`
                      # because `zip` records DOS file-times from the source
                      # mtime (build-clock-dependent without this). `zip` itself
                      # is idempotent — re-adding an existing entry replaces it.
                      # 315532800 = 1980-01-01, the ZIP DOS-date epoch floor.
                      __unpin_stage="$(mktemp -d)"
                      cp "$__unpin_meta" "$__unpin_stage/.unpin_meta"
                      touch -d "@''${SOURCE_DATE_EPOCH:-315532800}" "$__unpin_stage/.unpin_meta"
                      ( cd "$__unpin_stage" && zip -0 -X -j "$__unpin_bin" .unpin_meta ) >/dev/null
                      rm -rf "$__unpin_stage"
                    fi
                  else
                    # Plain PE/ELF/Mach-O — single objcopy pass.
                    __unpin_objcopy "$__unpin_bin"
                  fi

                  rm -f "$__unpin_meta"
                fi
              '';
            });
          in
          if hasExplicit && hasAuto then
            throw "withAliases: pass either `aliases` or `aliasesFromSymlinksIn`, not both"
          else if !hasExplicit && !hasAuto then
            throw "withAliases: requires `aliases` or `aliasesFromSymlinksIn`"
          else if hasExplicit && builtins.length aliases > 256 then
            throw "withAliases: ${toString (builtins.length aliases)} aliases exceeds limit 256"
          # Explicit-empty short-circuit: nothing to validate, nothing to
          # embed — return the input drv untouched (no nativeBuildInputs
          # bloat, no postInstall/postFixup hooks).
          else if hasExplicit && aliases == [ ] then drv
          # deepSeq forces each `validateAliasName` invocation now instead
          # of deferring it to when the postFixup string is constructed.
          # Without this, throws fire at build-graph realization, not eval.
          else builtins.deepSeq validatedAliases wrapped;

        # Why not overlays for per-package fixes? `appendOverlays` invalidates
        # `pkgsBuildHost.stdenv` → cascade rebuild of compiler-rt-libc-static, ninja,
        # python3 in pkgsStatic-darwin (none cached; Hydra only builds pkgsStatic-linux).
        # 30-60 min of darwin CI to add one configureFlag. Fake-cross via differing
        # config strings was tried and broke autotools (cross mode disables AC_RUN_IFELSE,
        # which apple-sdk's atf needs). So `drv.override` / `.overrideAttrs` inside the
        # native/ + mingw/ + mingw-overlay/ fix files is the only path keeping both the
        # cached toolchain AND autotools-native-mode configure runs.

        # Rebuild `drv` with every dep in `drv.override.__functionArgs` swapped for
        # its `pkgsStatic` counterpart (.a-only, no shared libs at all), falling back
        # to `dropSharedLibs` on the regular version when no pkgsStatic variant exists.
        #
        # Used by `native/tmux.nix` on darwin: pkgsStatic.tmux itself fails to link
        # (configure.ac passes `-static` globally → libSystem probe fails), so we keep
        # regular tmux but swap its deps for the static variants. Preferring pkgsStatic
        # over postFixup-delete dodges the dyld-at-build-time pitfall (ncurses ships
        # `tic`/`infocmp` binaries dynamically linked to `libncursesw.dylib`; deleting
        # the dylib breaks tmux-terminfo, which `tic`s at build time).
        withDepsSharedPruned = pkgs: drv:
          let
            fnArgs = drv.override.__functionArgs or { };
            isPrunableDrv = v:
              builtins.isAttrs v
              && (v.type or null) == "derivation"
              && v ? overrideAttrs;
            pruneOne = name:
              let
                staticDep = pkgs.pkgsStatic.${name} or null;
                regularDep = pkgs.${name} or null;
              in
              if staticDep != null && isPrunableDrv staticDep
              then { inherit name; value = staticDep; }
              else if regularDep != null && isPrunableDrv regularDep
              then { inherit name; value = dropSharedLibs regularDep; }
              else null;
            overrides = builtins.listToAttrs (
              builtins.filter (x: x != null)
                (map pruneOne (builtins.attrNames fnArgs))
            );
          in
          drv.override overrides;

        # `mingwStaticCross pkgs` = `pkgs.pkgsCross.mingwW64` + overlay that, on mingw:
        #
        # (1) Wraps stdenv with `makeStaticLibraries` → injects `--enable-static
        #     --disable-shared` (autotools), `-DBUILD_SHARED_LIBS=OFF` (cmake),
        #     `-Ddefault_library=static` (meson) into every mkDerivation.
        #
        # (2) Sets `stdenv.hostPlatform.isStatic = true`. A "white lie" at the platform
        #     attr level — NOT a re-instantiation. Upstream recipes key off isStatic
        #     directly (zlib's `shared ? !isStatic`, zstd's static knob, libpsl's .pc
        #     handling, ...) and produce .a-only outputs when they see it. Without this
        #     fudge we'd per-package-override each one.
        #
        # Safe for mingw: isStatic here is a build-flag convention; mingw-w64 / mcfgthread
        # produce byte-identical .a either way (no libc swap analogous to glibc→musl).
        # cc/bintools and the cross gcc come verbatim from cache.nixos.org — the overlay
        # only wraps mkDerivation.
        #
        # `if isMinGW` gate: pkgsBuildHost of the cross set is linux, so the then-branch
        # doesn't fire there and pkgsBuildHost.stdenv keeps its cache hash.
        mingwStaticCross = pkgs: pkgs.pkgsCross.mingwW64.appendOverlays [
          (selfPkgs: superPkgs:
            if superPkgs.stdenv.hostPlatform.isMinGW or false
            then
              let
                base = superPkgs.stdenvAdapters.makeStaticLibraries superPkgs.stdenv;
                # mingw-overlay/<name>.nix entries become overlay pieces at <name>.
                overlayEntries = nixpkgs.lib.mapAttrs
                  (_: f: f selfPkgs superPkgs)
                  mingwOverlayFixes;
              in
              {
                stdenv = base // {
                  hostPlatform = base.hostPlatform // { isStatic = true; };
                };
              } // overlayEntries
            else { })
        ];

        # Finalize a mingw binary for shipping. Input must already be built through
        # `mingwStaticCross` (libs are .a-only; `--enable-static --disable-shared`
        # already injected by the stdenv adapter).
        #
        # Adds the piece the per-library adapter can't reach: libtool-aware
        # `LDFLAGS=-all-static` at make-time so the FINAL link resolves to `.a` only.
        # Without it, libtool picks any `.dll.a` in the link path and the DLL-link hook
        # copies the matching `.dll` next to the binary.
        #
        # `staticDeps` threads via `.override` (libtool sees `.a` in the dep's lib
        # output); NOT applied as overlay — gcc itself uses zlib/zstd → full xgcc
        # rebuild. `filterConfigureFlag` strips flags the package adds unconditionally
        # (curl's `--without-ssl` when `opensslSupport = false`).
        mingwStaticBinary =
          { pkg
          , staticDeps ? { }
          , extraInputs ? [ ]
          , extraConfigureFlags ? [ ]
          , extraCFlags ? [ ]
          , filterConfigureFlag ? (_: true)
          , extraOverrides ? (_: { })
          }:
          let
            overridden = if staticDeps == { } then pkg else pkg.override staticDeps;
          in
          overridden.overrideAttrs
            (old:
              {
                stripAllList = [ "bin" ];
                buildInputs = (old.buildInputs or [ ]) ++ extraInputs;
                configureFlags =
                  (builtins.filter filterConfigureFlag (old.configureFlags or [ ]))
                  ++ extraConfigureFlags;
                # Make-time only. Passing via NIX_LDFLAGS at configure breaks autoconf's
                # "C compiler works" probe.
                makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
              }
              // (nixpkgs.lib.optionalAttrs (extraCFlags != [ ]) {
                # mingw headers (nghttp2, libpsl, libcurl, ...) default to
                # `__declspec(dllimport)`. Static consumers need *_STATICLIB defined or
                # the link leaves `__imp_*` unresolved.
                env = (old.env or { }) // {
                  NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " (
                    (nixpkgs.lib.optional (old ? env && old.env ? NIX_CFLAGS_COMPILE)
                      old.env.NIX_CFLAGS_COMPILE)
                    ++ extraCFlags);
                };
              })
              // extraOverrides old);

        packageWithMan = pkgs: name: drv:
          let
            stripped = drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; });
            outs = stripped.outputs or [ "out" ];
            # jq-style drvs have a `bin` output; bash/coreutils put binaries in `out`.
            primary = if builtins.elem "bin" outs then stripped.bin else stripped.out;
            hasMan = builtins.elem "man" outs;
          in
          pkgs.symlinkJoin {
            name = "${name}-${stripped.version}";
            paths = [ primary ] ++ nixpkgs.lib.optional hasMan stripped.man;
            passthru = { inherit (stripped) version pname; };
          };

        # Single output for both single- and multi-output drvs (strip vs symlinkJoin
        # bin+man). Keeps `nix build` producing the bare `result` symlink that
        # action-build's verify step looks for at `result/bin/<pkg>` — multi-output drvs
        # would otherwise land at `result-bin`/`result-man` and verify fails.
        strippedOrJoined = pkgs: name: drv:
          if (drv.outputs or [ "out" ]) == [ "out" ]
          then drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
          else packageWithMan pkgs name drv;

        # Standalone-binary flake template. Returns:
        #   packages.<system>.default                = native build (pkgsStatic)
        #   packages.aarch64-darwin."darwin-x86_64"  = cross x86_64-darwin
        #   packages.x86_64-linux."windows-x86_64"   = mingw-cross build
        #   apps.<system>.default                    = `nix run` entry
        #
        # `name` is looked up in native/<name>.nix and mingw/<name>.nix; falls back to
        # `pkgs.pkgsStatic.${name}` / `(mingwStaticCross pkgs).${name}`. Consumers wanting
        # full control pass `build` / `windowsBuild` directly. `binName` overrides when
        # bin name ≠ name. `nativeBuild = false` → windows-only (e.g. gvim: static GTK
        # infeasible on linux, MacVim is its own .app bundle).
        mkStandaloneFlake =
          { self
          , name
          , build ? null
          , windowsBuild ? null
          , binName ? name
          , nativeBuild ? true
          , windows ? false
          , windowsCosmo ? false
          , package_data ? true
          , bootstrap_naming ? false
          , own_software ? false
          }:
          let
            nixpkgsFor = forAllNative (system: import nixpkgs { inherit system; });

            rawBuild =
              if build != null then build
              else nativeFixes.${name} or (pkgs: pkgs.pkgsStatic.${name});
            stripped = pkgs: strippedOrJoined pkgs name (dropSharedLibs (rawBuild pkgs));

            # Windows runs on x86_64-linux runners. `allowUnsupportedSystem` because
            # most nixpkgs `meta.platforms` exclude mingw / cosmo → cross-built drv
            # would be filtered out. Dispatch order:
            #   windowsBuild   → consumer-supplied closure (curl Schannel,
            #                    vim/gvim Make_ming.mak)
            #   windowsCosmo   → mkPkgsCosmo (cosmocc-as-cross-stdenv); the
            #                    per-package fix lives in `cosmo/<name>.nix` as
            #                    an overlay fragment. Used when mingw isn't viable
            #                    (gnulib waitpid/fork POSIX assumptions: bash,
            #                    git, coreutils).
            #   windows        → mingw registry: `mingw/<name>.nix` or
            #                    `(mingwStaticCross pkgs).${name}` fallback.
            windowsEnabled = windows || windowsBuild != null || windowsCosmo;
            windowsPkgs = import nixpkgs {
              system = "x86_64-linux";
              config.allowUnsupportedSystem = true;
            };
            windowsRawBuild =
              if windowsBuild != null then windowsBuild
              else if windowsCosmo then (_pkgs: (mkPkgsCosmo { }).${name})
              else mingwFixes.${name} or (pkgs: (mingwStaticCross pkgs).${name});
            windowsPkg = strippedOrJoined windowsPkgs name
              (dropSharedLibs (windowsRawBuild windowsPkgs));
          in
          {
            packages = forAllNative (system:
              let pkgs = nixpkgsFor.${system}; in
              nixpkgs.lib.optionalAttrs nativeBuild { default = stripped pkgs; }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "aarch64-darwin") {
                "darwin-x86_64" = stripped pkgs.pkgsCross.x86_64-darwin;
              }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "x86_64-linux") {
                "linux-i686" = stripped pkgs.pkgsCross.musl32;
                # musl-power = powerpc64le-unknown-linux-musl. Debian calls it
                # "ppc64el" but uname returns "ppc64le" and the Rust ecosystem
                # (rustup, binstall) labels it the same way — we follow uname.
                "linux-ppc64le" = stripped pkgs.pkgsCross.musl-power;
                # riscv64 has no pre-cooked musl variant in nixpkgs.pkgsCross
                # (only glibc). Spell the crossSystem out by triple.
                "linux-riscv64" = stripped (import nixpkgs {
                  inherit system;
                  crossSystem = { config = "riscv64-unknown-linux-musl"; };
                });
              }
              // nixpkgs.lib.optionalAttrs (nativeBuild && system == "aarch64-linux") {
                # muslpi = armv6l-unknown-linux-musleabihf. Baseline armv6 ISA
                # (no NEON), runs on every ARM v6+ device (Pi 1/Zero through
                # Pi 4/5 in 32-bit mode, BeagleBone, Odroid, etc.). Labeled
                # "armv7l" because that's what `uname -m` returns on the
                # dominant target hardware and matches the Rust ecosystem
                # convention (ripgrep/fd/bat all use armv7 in this slot).
                "linux-armv7l" = stripped pkgs.pkgsCross.muslpi;
              }
              // nixpkgs.lib.optionalAttrs (windowsEnabled && system == "x86_64-linux") {
                "windows-x86_64" = windowsPkg;
              });

            apps = nixpkgs.lib.optionalAttrs nativeBuild (forAllNative (system: {
              default = {
                type = "app";
                program = "${self.packages.${system}.default}/bin/${binName}";
              };
            }));

            # Read by unpins/action-build to drive CI config.
            manifest = {
              inherit name package_data bootstrap_naming own_software nativeBuild;
            };
          };

        # Native cosmoStdenv. Used by playground/{bash,coreutils,dash,links} for
        # in-tree builds against the `$COSMOS` shared prefix. The full result is
        # `stdenv // { cosmocc, cosmoCCUnwrapped, cosmoBintoolsUnwrapped,
        # platformBits, mkCrossWiring, version }` — consumers commonly want
        # `cosmoStdenv.mkDerivation` and `cosmoStdenv.platformBits`.
        cosmoStdenv = pkgs: import ./cosmocc.nix { inherit pkgs; };

        # pkgsCosmo: a full nixpkgs package set re-evaluated with cosmocc as the
        # cross-toolchain. Splicing handled by nixpkgs (buildPackages stays glibc,
        # host packages target cosmo). Per-package quirks live in cosmo/<name>.nix.
        #
        # The applyPatches step adds cosmo to nixpkgs's lib/systems/{parse,inspect}
        # (small, see ./cosmo-lib-systems.patch). replaceCrossStdenv injects our
        # cosmocc cc-wrapper into the cross-stdenv that nixpkgs constructs.
        #
        # `targetArch` picks the cosmocc single-arch driver. cosmocc ships both
        # x86_64 and aarch64; arch must match `cosmoStdenv`'s host (see cosmocc.nix
        # `archPrefix`). Cross-arch (e.g. x86_64-linux host building aarch64-cosmo)
        # isn't wired — needs a buildPackages.pkgsCross stanza, not exposed yet.
        #
        # Most packages need `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` because their
        # `meta.platforms` doesn't list cosmo.
        mkPkgsCosmo =
          { system ? "x86_64-linux"
          , targetArch ? "x86_64"
          }:
          let
            basePkgs = nixpkgs.legacyPackages.${system};
            nixpkgsPatched = basePkgs.applyPatches {
              name = "nixpkgs-cosmo";
              src = nixpkgs.outPath;
              patches = [ ./cosmo-lib-systems.patch ];
            };
            # Pass fixLib so overlay fragments can call `lib.withAliases`
            # (defined here in nix-lib's `lib`), not just nixpkgs.lib.
            cosmoOverlay = import ./cosmo { lib = nixpkgs.lib // lib; };
            targetConfig = "${targetArch}-unknown-cosmo-gnu";
          in
          import nixpkgsPatched {
            inherit system;
            crossSystem = {
              config = targetConfig;
              libc = null;
            };
            overlays = [ cosmoOverlay ];
            config.replaceCrossStdenv = { buildPackages, baseStdenv }:
              let
                cs = import ./cosmocc.nix { pkgs = buildPackages; };
                wiring = cs.mkCrossWiring {
                  inherit buildPackages baseStdenv targetArch;
                  targetPrefix = "${targetConfig}-";
                };
              in
              wiring.stdenv;
          };
      };

      # Per-target fixes, auto-loaded from sibling directories.
      # See lib.mkStandaloneFlake and lib.mingwStaticCross for how they're consumed.
      # Fix files use nixpkgs.lib for stdlib (hasSuffix, filterAttrs, …) AND our
      # helpers (withDepsSharedPruned, mingwStaticCross, …) — fuse both into one
      # `lib` for them so they can write `lib.X` uniformly.
      fixLib = nixpkgs.lib // lib;
      nativeFixes = import ./native { lib = fixLib; };
      mingwFixes = import ./mingw { lib = fixLib; };
      mingwOverlayFixes = import ./mingw-overlay { lib = fixLib; };
    in
    {
      inherit lib;
    };
}
