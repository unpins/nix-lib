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
            explicitCsv = nixpkgs.lib.concatStringsSep ","
              (if hasExplicit then aliases else [ ]);
            wrapped = drv.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ])
                ++ [
                  pkgs.buildPackages.llvm
                  # unzip/zip + python3Minimal are only exercised on cosmocc
                  # outputs (tail-ZIP detection, offset compute, stored append).
                  # ~10 MB of build closure, never linked into shipped artifacts.
                  pkgs.buildPackages.unzip
                  pkgs.buildPackages.zip
                  pkgs.buildPackages.python3Minimal
                ];

              postInstall = (old.postInstall or "")
                + nixpkgs.lib.optionalString hasAuto ''
                __unpin_aliases=""
                for f in "$out/${aliasesFromSymlinksIn}"/*; do
                  [ -L "$f" ] || continue
                  n="$(basename "$f")"
                  [ "$n" = "${primary}" ] && continue
                  # Skip names the unpin reader's `validate_alias` would reject
                  # (first char must be [a-z0-9]). Filters coreutils' `[`
                  # applet and any future oddballs at the source.
                  case "$n" in [a-z0-9]*) ;; *) continue ;; esac
                  __unpin_aliases="''${__unpin_aliases:+$__unpin_aliases,}$n"
                done
                printf '%s' "$__unpin_aliases" > "$NIX_BUILD_TOP/.unpin-aliases"
                find "$out/${aliasesFromSymlinksIn}" -maxdepth 1 -type l -delete
              '';

              postFixup = (old.postFixup or "") + ''
                ${if hasExplicit
                  then "__unpin_aliases='${explicitCsv}'"
                  else ''__unpin_aliases="$(cat "$NIX_BUILD_TOP/.unpin-aliases")"''}
                __unpin_meta="$(mktemp)"
                # Octal escapes (\NNN) for portability — \xHH isn't POSIX,
                # though every stdenv shell we use happens to support it.
                # Marker bytes mirror aliases.rs MARKER_BEGIN/MARKER_END verbatim.
                printf '\377\377UNPIN_META_v1_7f3a4e\377\377\nALIASES=%s\n\377\377UNPIN_META_END_7f3a4e\377\377\n' \
                  "$__unpin_aliases" > "$__unpin_meta"

                __unpin_bin="$out/bin/${primary}"

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
                    llvm-objcopy \
                      --add-section .unpin_meta="$__unpin_meta" \
                      --set-section-flags .unpin_meta=readonly,noload \
                      "$__unpin_bin"
                  else
                    # ZIP has functional content (zoneinfo etc.). Append our
                    # block as a stored entry — bytes appear verbatim so the
                    # scanner finds the sentinels; -X drops uid/gid for
                    # reproducible builds.
                    __unpin_stage="$(mktemp -d)"
                    cp "$__unpin_meta" "$__unpin_stage/.unpin_meta"
                    ( cd "$__unpin_stage" && zip -0 -X -j "$__unpin_bin" .unpin_meta ) >/dev/null
                    rm -rf "$__unpin_stage"
                  fi
                else
                  # Plain PE/ELF/Mach-O — single objcopy pass.
                  llvm-objcopy \
                    --add-section .unpin_meta="$__unpin_meta" \
                    --set-section-flags .unpin_meta=readonly,noload \
                    "$__unpin_bin"
                fi

                rm -f "$__unpin_meta"
              '';
            });
          in
          if hasExplicit && hasAuto then
            throw "withAliases: pass either `aliases` or `aliasesFromSymlinksIn`, not both"
          else if !hasExplicit && !hasAuto then
            throw "withAliases: requires `aliases` or `aliasesFromSymlinksIn`"
          else wrapped;

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
            # most nixpkgs `meta.platforms` exclude mingw → cross-built drv would be
            # filtered out. `windows = true` → registry lookup. `windowsBuild` →
            # consumer-supplied from scratch (curl Schannel, vim/gvim Make_ming.mak).
            windowsEnabled = windows || windowsBuild != null;
            windowsPkgs = import nixpkgs {
              system = "x86_64-linux";
              config.allowUnsupportedSystem = true;
            };
            windowsRawBuild =
              if windowsBuild != null then windowsBuild
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
            cosmoOverlay = import ./cosmo { inherit (nixpkgs) lib; };
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
