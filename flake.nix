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

        isLinuxSys = system: nixpkgs.lib.hasSuffix "-linux" system;
        isDarwinSys = system: nixpkgs.lib.hasSuffix "-darwin" system;

        # Append `flags` (string or list) to NIX_CFLAGS_COMPILE.
        #
        # `__structuredAttrs = true` drvs (bash, findutils, grep, dash, …)
        # carry the flag inside `env.NIX_CFLAGS_COMPILE`. Writing a top-level
        # `NIX_CFLAGS_COMPILE` on top of that collides — nix's mkDerivation
        # refuses with "attribute set cannot contain any attributes passed to
        # derivation". So we detect where the existing value lives and append
        # in-place; never both.
        appendCFlags = drv: flags:
          let
            flagStr = builtins.concatStringsSep " "
              (if builtins.isList flags then flags else [ flags ]);
          in
          drv.overrideAttrs (old:
            if old ? env && old.env ? NIX_CFLAGS_COMPILE then {
              env = old.env // {
                NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " " + flagStr;
              };
            } else if old ? NIX_CFLAGS_COMPILE then {
              NIX_CFLAGS_COMPILE = old.NIX_CFLAGS_COMPILE + " " + flagStr;
            } else {
              NIX_CFLAGS_COMPILE = flagStr;
            });

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

        # Curated terminfo entries baked into libtinfo.a via ncurses
        # `--with-fallbacks=`. Covers what users actually hit across the
        # three OSes: legacy (xterm/vt100/ansi/dumb), Linux console
        # (linux), multiplexers (screen/tmux), Windows shells (mintty/
        # cygwin/ms-terminal/vscode), modern emulators (alacritty/foot/
        # kitty/ghostty), DE defaults (gnome/konsole), suckless (st),
        # rxvt, putty, macOS Terminal.app (nsterm), iTerm2 direct-color.
        #
        # Why bake at all: the unpins promise is "single binary that
        # runs anywhere" — we can't assume `/usr/share/terminfo` or
        # `/etc/terminfo` exists on the host (scratch containers, Alpine
        # without ncurses-terminfo-base, raw Windows, ...). Embedding
        # ~35 essentials keeps libedit / ncurses-TUI consumers
        # functional with zero data files. See docs/runtime-data.md for
        # the "complete coverage" path (data archive) — not yet wired.
        #
        # Modern entries that ncurses 6.5 (nixpkgs 25.11) doesn't ship
        # — `xterm-ghostty`, `xterm-kitty`, `rxvt-unicode*` — come from
        # `extra-terminfo.src` (appended pre-tic via
        # `embedFallbackTerminfo*`'s postPatch). The `xterm-…` aliases
        # are the names Ghostty/kitty actually set in $TERM by default;
        # ncurses' own `kitty`/`ghostty` entries lack those aliases, so
        # we ship the upstream-canonical entries separately.
        fallbackTerminals =
          "xterm,xterm-color,xterm-256color,ansi,vt100,vt102,vt220,dumb,"
          + "linux,mintty,cygwin,ms-terminal,vscode,"
          + "screen,screen-256color,tmux,tmux-256color,"
          + "alacritty,alacritty-direct,foot,"
          + "kitty,xterm-kitty,xterm-ghostty,wezterm,"
          + "gnome,gnome-256color,konsole,konsole-256color,"
          + "st,st-256color,Eterm,"
          + "rxvt,rxvt-256color,rxvt-unicode,rxvt-unicode-256color,"
          + "iterm2-direct,nsterm,putty,putty-256color";

        # Patch ncurses to (a) append `extra-terminfo.src` to the source
        # database so newer entries (ghostty, ...) are known to tic at
        # build time, then (b) add `--with-fallbacks=<fallbackTerminals>`
        # so each entry is compiled into libtinfo.a as a C array. Host
        # terminfo files still take precedence at runtime (database
        # lookup stays enabled).
        embedFallbackTerminfo = ncurses: ncurses.overrideAttrs (oa: {
          postPatch = (oa.postPatch or "") + ''
            cat ${./extra-terminfo.src} >> misc/terminfo.src
          '';
          configureFlags = (oa.configureFlags or [ ]) ++ [
            "--with-fallbacks=${fallbackTerminals}"
          ];
        });

        # Same as embedFallbackTerminfo plus `--disable-database` — the
        # compiled libtinfo.a no longer tries the runtime path lookup.
        # For Windows targets (cosmo, mingw) where the binary's
        # compiled-in `/nix/store/.../share/terminfo` doesn't exist on
        # the user's machine and there's no system convention to fall
        # back on; the only source of truth becomes the baked array.
        embedFallbackTerminfoOnly = ncurses: ncurses.overrideAttrs (oa: {
          postPatch = (oa.postPatch or "") + ''
            cat ${./extra-terminfo.src} >> misc/terminfo.src
          '';
          configureFlags = (oa.configureFlags or [ ]) ++ [
            "--disable-database"
            "--with-fallbacks=${fallbackTerminals}"
          ];
        });

        # Strip `--enable-static`/`--disable-shared` from configureFlags on
        # darwin. Background: pkgsStatic adds both flags to every derivation.
        # The configure.ac in many GNU-ish packages (dash, htop, ...)
        # translates `--enable-static` into `export LDFLAGS="-static"`, which
        # then breaks every subsequent AC_CHECK_LIB probe — darwin has only
        # libSystem.dylib, no libSystem.a. The probes fail and consumers
        # think their deps are missing (libedit, libsensors, ...).
        #
        # Filtering the flags lets each pkgsStatic input still contribute a
        # `.a` to the link line; only libSystem stays implicitly-dynamic,
        # matching the catalog's darwin policy. Applied automatically inside
        # `mkStandaloneFlake`'s native pipeline so individual fix files don't
        # need to repeat the workaround.
        #
        # Not applied to mingw / cosmo cross builds (no libSystem issue, and
        # --enable-static there is genuinely a static link request).
        filterEnableStaticOnDarwin = drv:
          if (drv.stdenv.hostPlatform.isDarwin or false)
          then drv.overrideAttrs (old: {
            configureFlags = nixpkgs.lib.filter
              (f: f != "--enable-static" && f != "--disable-shared")
              (old.configureFlags or [ ]);
          })
          else drv;

        # Embed a package's multi-call alias list into `$out/bin/<primary>` as a
        # `unpin/aliases` entry of the binary's embedded ZIP, so unpin's
        # installer can spawn argv[0]-dispatch links (xz → xzcat/unxz/lzma…) at
        # `unpin install` time. The container is a plain ZIP (one name per line
        # in `unpin/aliases`), located/read by unpin via the ZIP's native EOCD —
        # see docs/embedded-metadata.md and `unpin/src/meta.rs`. Embedding is the
        # shared `__unpin_embed_subtree` (see `unpinEmbedSh`).
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
        # Alias security (no marker needed): aliases are honored at install time
        # only for catalog-owner packages, and every name passes the blocklist —
        # both upstream of the reader. See docs/embedded-metadata.md §4.
        # Shared embed primitive for withAliases/withMan: add a staging `unpin/`
        # subtree to the binary's embedded ZIP (docs/embedded-metadata.md). If
        # the binary already carries a tail-ZIP (cosmo APE runtime, or a prior
        # embed step), add entries to it; otherwise build a standalone ZIP and
        # append it as an overlay at EOF. On Mach-O the current EOF is past
        # LC_CODE_SIGNATURE, so the overlay is outside the signed range and
        # signing stays valid. `zip -y` keeps `.so` symlinks; mtimes are pinned
        # and `-X` drops uid/gid for reproducibility. Idempotent: re-adding an
        # entry replaces it, so re-runs don't accrete duplicate ZIPs.
        unpinEmbedSh = ''
          __unpin_embed_subtree() {
            __ues_bin="$1"; __ues_stage="$2"
            if [ ! -f "$__ues_bin" ]; then
              echo "unpin embed: $__ues_bin does not exist" >&2; exit 1
            fi
            find "$__ues_stage/unpin" -exec touch -h -d "@''${SOURCE_DATE_EPOCH:-315532800}" {} + 2>/dev/null || true
            __ues_names="$(cd "$__ues_stage" && find unpin -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort)"
            [ -n "$__ues_names" ] || return 0
            if unzip -Z1 "$__ues_bin" 2>/dev/null | grep -qxF .cosmo; then
              # cosmo APE: ADD our entries to the existing tail-ZIP. We must not
              # append a second ZIP after it — cosmo's loader finds its `/zip/`
              # runtime via the end-of-file EOCD, and a trailing ZIP would shadow
              # it. cosmo's ZIP has file-adjusted offsets, so `zip` can edit it.
              ( cd "$__ues_stage" && printf '%s\n' "$__ues_names" | zip -y -X -q "$__ues_bin" -@ )
            else
              # Fresh binary, or a binary that already carries one of OUR overlay
              # ZIPs (from a prior embed step). Append our subtree as a NEW
              # overlay ZIP at EOF. We don't try to edit a prior overlay: `zip`
              # rejects an unadjusted-prefix overlay ("structure invalid"), and
              # the reader unions `unpin/*` across every embedded ZIP anyway — so
              # aliases-overlay + man-overlay read back as one set. zip must
              # CREATE the archive (a bare `mktemp` file is empty and rejected),
              # so point it at a fresh path.
              __ues_d="$(mktemp -d)"
              ( cd "$__ues_stage" && printf '%s\n' "$__ues_names" | zip -y -X -q "$__ues_d/m.zip" -@ )
              cat "$__ues_d/m.zip" >> "$__ues_bin"
              rm -rf "$__ues_d"
            fi
          }
        '';

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
                  # Build + add to the binary's embedded ZIP. Build-only (~few
                  # MB closure), never linked into the shipped artifact.
                  pkgs.buildPackages.zip
                  pkgs.buildPackages.unzip
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
                # Mirrors MAX_ALIASES = 512 in unpin/src/aliases.rs.
                if [ "$__unpin_count" -gt 512 ]; then
                  echo "withAliases: collected $__unpin_count aliases, exceeds limit of 512" >&2
                  exit 1
                fi
                printf '%s' "$__unpin_aliases" > "$NIX_BUILD_TOP/.unpin-aliases"
                find "''${${binOutputName}}/${aliasesFromSymlinksIn}" -maxdepth 1 -type l -delete
              '';

              postFixup = (old.postFixup or "") + ''
                ${unpinEmbedSh}
                ${if hasExplicit
                  then "__unpin_aliases='${explicitCsv}'"
                  else ''__unpin_aliases="$(cat "$NIX_BUILD_TOP/.unpin-aliases")"''}

                # Short-circuit: nothing to embed when the collected/declared
                # list ended up empty (auto-mode: no symlinks matched the
                # validator; explicit-mode: caller passed `aliases = [ ]`).
                if [ -z "$__unpin_aliases" ]; then
                  echo "withAliases: no aliases to embed for ${primary}, skipping" >&2
                else
                  __unpin_bin="''${${binOutputName}}/bin/${primary}"
                  if [ ! -f "$__unpin_bin" ] && [ -f "$__unpin_bin.exe" ]; then
                    __unpin_bin="$__unpin_bin.exe"
                  fi
                  if [ ! -f "$__unpin_bin" ]; then
                    echo "withAliases: $__unpin_bin does not exist" >&2
                    exit 1
                  fi
                  # Write `unpin/aliases` (one name per line) into a staging tree
                  # and add it to the binary's embedded ZIP. Aliases are a
                  # security boundary, but that is enforced at install time
                  # (catalog-owner gate + blocklist), not here — we just ship
                  # the declared list.
                  __unpin_stage="$(mktemp -d)"
                  mkdir -p "$__unpin_stage/unpin"
                  printf '%s' "$__unpin_aliases" | tr ',' '\n' > "$__unpin_stage/unpin/aliases"
                  __unpin_embed_subtree "$__unpin_bin" "$__unpin_stage"
                  rm -rf "$__unpin_stage"
                fi
              '';
            });
          in
          if hasExplicit && hasAuto then
            throw "withAliases: pass either `aliases` or `aliasesFromSymlinksIn`, not both"
          else if !hasExplicit && !hasAuto then
            throw "withAliases: requires `aliases` or `aliasesFromSymlinksIn`"
          else if hasExplicit && builtins.length aliases > 512 then
            throw "withAliases: ${toString (builtins.length aliases)} aliases exceeds limit 512"
          # Explicit-empty short-circuit: nothing to validate, nothing to
          # embed — return the input drv untouched (no nativeBuildInputs
          # bloat, no postInstall/postFixup hooks).
          else if hasExplicit && aliases == [ ] then drv
          # deepSeq forces each `validateAliasName` invocation now instead
          # of deferring it to when the postFixup string is constructed.
          # Without this, throws fire at build-graph realization, not eval.
          else builtins.deepSeq validatedAliases wrapped;

        # Embed the package's OWN man pages as `unpin/man/<name>.<section>`
        # entries of the binary's embedded ZIP (roff verbatim; `.so` stubs as
        # ZIP symlink entries), so `unpin man <pkg>` reads docs straight out of
        # the binary — no companion data tarball. `./mkmeta.py` populates a
        # staging `unpin/man/` tree, then the shared `__unpin_embed_subtree`
        # (see `unpinEmbedSh`) adds it to the binary's ZIP.
        #
        # Composition with withAliases: order-free. Both just ADD entries to the
        # one embedded ZIP (creating it if absent), so neither clobbers the
        # other — the old Mach-O "withMan after withAliases" ordering invariant
        # is gone. See docs/embedded-metadata.md.
        # `manRoot`: when null, harvest man from the drv's own outputs
        # (`$man`/`$out`) — the native path, where the static build produces
        # man. When set to a store path, read `$manRoot/share/man` instead —
        # used by the windows/cosmo path, where the cross build ships no man
        # so we source the (platform-independent) pages from a man-bearing
        # build of the same package + version.
        withMan = pkgs: { primary, manRoot ? null }: drv:
          let
            binOutputName =
              let outs = drv.outputs or [ "out" ];
              in
              if builtins.elem "bin" outs then "bin"
              else if builtins.elem "out" outs then "out"
              else builtins.head outs;
          in
          drv.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ])
              ++ [
                pkgs.buildPackages.python3Minimal  # mkmeta.py builds the man tree
                pkgs.buildPackages.zip
                pkgs.buildPackages.unzip
              ];

            postFixup = (old.postFixup or "") + ''
              ${unpinEmbedSh}
              # Locate the man tree to embed.
              ${if manRoot != null then ''
                # Externally supplied man source (windows/cosmo path).
                __unpin_manroot="${manRoot}"
                if [ ! -d "$__unpin_manroot/share/man" ]; then
                  echo "withMan: manRoot ${manRoot} has no share/man" >&2
                  __unpin_manroot=""
                fi
              '' else ''
                # Harvest from the drv's own outputs (native path). nixpkgs puts
                # man in the `man` output when present; pkgsStatic single-output
                # drvs keep it in `out`/the bin output under share/man.
                __unpin_manroot=""
                for __unpin_d in "''${man:-}" "''${${binOutputName}}" "''${out:-}"; do
                  if [ -n "$__unpin_d" ] && [ -d "$__unpin_d/share/man" ]; then
                    __unpin_manroot="$__unpin_d"; break
                  fi
                done
              ''}
              if [ -z "$__unpin_manroot" ]; then
                echo "withMan: no share/man found for ${primary}, skipping" >&2
              else
                # mkmeta.py populates a staging `unpin/man/` tree (roff files +
                # symlinks for `.so`). Exit 3 = no man pages (legit skip); any
                # other nonzero = real failure → fail the build (don't silently
                # ship man-less). `|| rc=$?` keeps errexit from aborting first.
                __unpin_stage="$(mktemp -d)"
                __unpin_rc=0
                python3 ${./mkmeta.py} "$__unpin_manroot" "$__unpin_stage" || __unpin_rc=$?
                if [ "$__unpin_rc" = 3 ]; then
                  echo "withMan: no man pages for ${primary}, skipping" >&2
                elif [ "$__unpin_rc" != 0 ]; then
                  echo "withMan: mkmeta.py failed (exit $__unpin_rc) for ${primary}" >&2
                  exit "$__unpin_rc"
                else
                  __unpin_bin="''${${binOutputName}}/bin/${primary}"
                  # Windows artifacts are `<primary>.exe`.
                  if [ ! -f "$__unpin_bin" ] && [ -f "$__unpin_bin.exe" ]; then
                    __unpin_bin="$__unpin_bin.exe"
                  fi
                  if [ ! -f "$__unpin_bin" ]; then
                    # Man exists but we can't find the primary binary (binName
                    # mismatch / unusual layout). Since embedMan is default-on
                    # across the catalog, warn and skip rather than fail the
                    # build — worst case is no embedded man for this package.
                    echo "withMan: man found but $__unpin_bin missing — skipping embed for ${primary}" >&2
                  else
                    # No ordering guard needed: __unpin_embed_subtree ADDS man
                    # entries to whatever ZIP withAliases left (or creates one),
                    # so it can't clobber the alias entry.
                    __unpin_embed_subtree "$__unpin_bin" "$__unpin_stage"
                  fi
                fi
                rm -rf "$__unpin_stage"
              fi
            '';
          });

        # Drop Cosmopolitan's `.symtab.amd64` from a cosmo APE's tail-ZIP.
        # That entry is the symbol table cosmocc's apelink adds for crash
        # backtraces (`--ftrace`/`--strace`), ~30-80 KB deflated and unused at
        # runtime — stdenv `strip` can't reach it (it's a ZIP member, not an
        # ELF section). `zip -d` removes just that member, preserving the PE
        # prefix, `.cosmo`, any `usr/share/zoneinfo/*`, and our `unpin/*` entries.
        # Self-guarding: no-op on mingw PE (no tail-ZIP). Apply AFTER withMan
        # so it trims what's left once the man block is embedded.
        withCosmoStrip = pkgs: { primary }: drv:
          let
            binOutputName =
              let outs = drv.outputs or [ "out" ];
              in
              if builtins.elem "bin" outs then "bin"
              else if builtins.elem "out" outs then "out"
              else builtins.head outs;
          in
          drv.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ])
              ++ [ pkgs.buildPackages.zip pkgs.buildPackages.unzip ];
            postFixup = (old.postFixup or "") + ''
              __unpin_cs="''${${binOutputName}}/bin/${primary}"
              if [ ! -f "$__unpin_cs" ] && [ -f "$__unpin_cs.exe" ]; then
                __unpin_cs="$__unpin_cs.exe"
              fi
              # `grep -xF` *without* -q on purpose: nixpkgs' build shell runs
              # with `set -o pipefail`, and `grep -q` exits on the first match
              # → SIGPIPE to `unzip` → the pipeline reports failure even when
              # the entry IS present. Reading to EOF sidesteps that.
              if [ -f "$__unpin_cs" ] \
                 && unzip -Z1 "$__unpin_cs" 2>/dev/null | grep -xF '.symtab.amd64' >/dev/null; then
                zip -d "$__unpin_cs" .symtab.amd64 >/dev/null
              fi
            '';
          });

        # Why not overlays for per-package fixes? `appendOverlays` invalidates
        # `pkgsBuildHost.stdenv` → cascade rebuild of compiler-rt-libc-static, ninja,
        # python3 in pkgsStatic-darwin (none cached; Hydra only builds pkgsStatic-linux).
        # 30-60 min of darwin CI to add one configureFlag. Fake-cross via differing
        # config strings was tried and broke autotools (cross mode disables AC_RUN_IFELSE,
        # which apple-sdk's atf needs). So `drv.override` / `.overrideAttrs` inside the
        # consumer's `build`/`windowsBuild` closures (and the lib-only
        # native-overlay/ + mingw-overlay/ overlay fragments) is the only path
        # keeping both the cached toolchain AND autotools-native-mode configure
        # runs.

        # Rebuild `drv` with every dep in `drv.override.__functionArgs` swapped for
        # its `pkgsStatic` counterpart (.a-only, no shared libs at all), falling back
        # to `dropSharedLibs` on the regular version when no pkgsStatic variant exists.
        #
        # Used by `tmux/flake.nix`'s darwin build closure: pkgsStatic.tmux itself fails to link
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
            withMingwOverrides = overridden.overrideAttrs (old: {
              stripAllList = [ "bin" ];
              buildInputs = (old.buildInputs or [ ]) ++ extraInputs;
              configureFlags =
                (builtins.filter filterConfigureFlag (old.configureFlags or [ ]))
                ++ extraConfigureFlags;
              # Make-time only. Passing via NIX_LDFLAGS at configure breaks autoconf's
              # "C compiler works" probe.
              makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
            } // extraOverrides old);
          in
          # mingw headers (nghttp2, libpsl, libcurl, ...) default to
          # `__declspec(dllimport)`. Static consumers need *_STATICLIB defined or
          # the link leaves `__imp_*` unresolved.
          if extraCFlags == [ ]
          then withMingwOverrides
          else appendCFlags withMingwOverrides extraCFlags;

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
        # `name` is the user-facing id (catalog/gh-repo/binary). `pkgsAttr`
        # overrides the nixpkgs / nativeFixes / pkgsCross.cosmo lookup when the
        # nixpkgs attribute differs (e.g. nixpkgs ships `links2`, we ship as
        # `links`). Falls back to `pkgs.pkgsStatic.${pkgsAttr}` /
        # `pkgs.pkgsCross.mingwW64.${pkgsAttr}` / `pkgs.pkgsCross.cosmo.${pkgsAttr}`.
        # Consumers wanting full control pass `build` / `windowsBuild` directly.
        # `binName` overrides when bin name ≠ name. `nativeBuild = false` →
        # windows-only (e.g. gvim: static GTK infeasible on linux, MacVim is its
        # own .app bundle). `linuxOnly = true` → suppresses every darwin attr
        # from packages.<sys>, used for Linux-kernel-only tools (kmod,
        # util-linux, shadow, procps-ng, iproute2).
        mkStandaloneFlake =
          { self
          , name
          , build ? null
          , windowsBuild ? null
          , binName ? name
          , pkgsAttr ? name
          , nativeBuild ? true
          , windows ? false
          , windowsCosmo ? false
          , linuxOnly ? false
          # No companion data tarball by default. Runtime data is embedded in
          # the binary (file's magic, vim/gvim's VFS runtime) and man pages go
          # in the embedded ZIP (embedMan), so `share/` is redundant.
          # Set true only for a package that genuinely needs a side asset.
          , package_data ? false
          , bootstrap_naming ? false
          , own_software ? false
          # Embed the package's own man pages into the binary via `withMan`
          # (as `unpin/man/*` ZIP entries), so `unpin man <pkg>` works offline with
          # no companion asset. Default-on across the catalog: packages with no
          # man (codec libs, coreutils/busybox) skip gracefully. Set false to
          # opt a package out.
          , embedMan ? true
          # Override the man source for the windows/cosmo binary. The cross
          # build ships no man of its own, so by default we graft the
          # version-locked pages from the x86_64-linux nixpkgs build of
          # `pkgsAttr` (see `winManSrc` below). That harvests EVERY page the
          # upstream ships — including tools/libs the unpins binary doesn't
          # actually carry (e.g. ffmpeg's ffplay.1 / libav*.3). Set this to a
          # store path with `share/man` to embed exactly that set instead, so
          # the windows binary's man matches what native/darwin embed (parity).
          # null = keep the nixpkgs graft (default; unchanged for every package
          # that doesn't opt in).
          , winManRoot ? null
          # Opt-in smoke-test args, e.g. `[ "--version" ]`. action-build
          # runs `<bin> ${smoke[*]}` after each build on runners with a
          # matching ABI (and on a Windows runner for windows-x86_64).
          # Exit 0 alone is too lax — some tools print "Unknown option"
          # and still exit 0 (links does this on Windows). Pair with
          # `smokePattern` to also require a stdout substring match.
          # Skip both with null when the binary lacks a quick non-
          # interactive probe.
          , smoke ? null
          , smokePattern ? null
          # optimize: knobs for opt-level / stack protector / LTO. Defaults
          # merged with `{ lto = false; opt = null; ssp = true; }`. Keys:
          #
          #   lto = true       → enable mkPkgsLTO overlay; chain-LTO consumer
          #                       + its level-1 buildInputs (Linux native
          #                       only — mingw/cosmocc fall through). OFF by
          #                       default since the LTO chain has produced
          #                       systemic recurring failures (autoconf
          #                       conftest leakage, ltrans debug-info refs,
          #                       muslLTO symbol internalization, buildInput
          #                       test-suite miscompiles). For tiny static
          #                       CLIs the size win is 5-15% and the latency
          #                       win is invisible (ms-scale runs), so the
          #                       maintenance cost was not justified. Opt
          #                       in per-package when a hot path genuinely
          #                       benefits.
          #   opt = "-Os"      → appended to NIX_CFLAGS_COMPILE (wins over
          #                       upstream). null leaves it to upstream
          #                       (~ -O2). When LTO is active, null is
          #                       resolved to -O2 inside the overlay.
          #   ssp = false      → drop stack protector + skip the LTO
          #                       `-Wl,-u,__stack_chk_fail` retention flag.
          , optimize ? { }
          }:
          let
            optimize_ = { lto = false; opt = null; ssp = true; } // optimize;
            inherit (optimize_) lto opt ssp;
            ltoOpt = if opt == null then "-O2" else opt;
            # LTO overlay applies on Linux only — musl is Linux-specific
            # and the cross-darwin path doesn't have an analogous chain
            # we want to rewire yet. Darwin/cross fall back to stock pkgs.
            nixpkgsFor = forAllNative (system:
              if lto && isLinuxSys system
              then mkPkgsLTO { inherit system; opt = ltoOpt; inherit ssp; pkgName = pkgsAttr; }
              else import nixpkgs { inherit system; });

            # Apply opt/ssp knobs to a built drv. No-op when both at
            # default (opt = null + ssp = true) so cache.nixos.org hits
            # stay intact for packages that don't override.
            applyOptSsp = drv:
              if opt == null && ssp then drv
              else
                let
                  flags = (nixpkgs.lib.optional (opt != null) opt)
                       ++ (nixpkgs.lib.optional (!ssp) "-fno-stack-protector");
                in
                (appendCFlags drv flags).overrideAttrs (old: {
                  hardeningDisable = (old.hardeningDisable or [ ])
                    ++ (if ssp then [ ] else [ "stackprotector" ]);
                });

            rawBuild =
              if build != null then build
              else nativeFixes.${pkgsAttr} or (pkgs: pkgs.pkgsStatic.${pkgsAttr});
            stripped = pkgs:
              let
                base = dropSharedLibs (filterEnableStaticOnDarwin (applyOptSsp (rawBuild pkgs)));
                # withMan must run on the underlying drv (it edits the bin
                # output and reads the man output) BEFORE strippedOrJoined
                # collapses multi-output drvs into a symlinkJoin.
                withMaybeMan =
                  if embedMan then withMan pkgs { primary = binName; } base
                  else base;
              in
              strippedOrJoined pkgs name withMaybeMan;

            # Windows runs on x86_64-linux runners. `allowUnsupportedSystem` because
            # most nixpkgs `meta.platforms` exclude mingw / cosmo → cross-built drv
            # would be filtered out. Dispatch order:
            #   windowsBuild   → consumer-supplied closure. For mingw, returns
            #                    `(mingwStaticCross pkgs).${name}.overrideAttrs …`;
            #                    for cosmocc, returns `(cosmoStaticCross pkgs).${name}
            #                    .overrideAttrs …`. Per-binary cosmo recipes live
            #                    in `<consumer>/cosmo.nix` sidecars, mingw recipes
            #                    inline in the consumer's `windowsBuild`.
            #   windowsCosmo   → `(cosmoStaticCross pkgs).${pkgsAttr}`. The
            #                    cosmo cross stdenv carries an apelink setup
            #                    hook that auto-converts ELF → PE32+ in
            #                    fixupPhase, so no helper wrapping is needed.
            #                    Use for cosmo builds where vanilla nixpkgs
            #                    cross builds cleanly and no further consumer
            #                    customization is needed. Most catalog cosmo
            #                    packages have extra quirks (drop symlinks,
            #                    withAliases, configureFlags) and use
            #                    `windowsBuild = import ./cosmo.nix` instead.
            #   windows        → plain `(mingwStaticCross pkgs).${pkgsAttr}`,
            #                    no consumer customization.
            windowsEnabled = windows || windowsBuild != null || windowsCosmo;
            # windowsPkgs is the single root from which BOTH cross targets live:
            #   pkgsCross.mingwW64  →  vanilla nixpkgs cross
            #   pkgsCross.cosmo     →  cosmocc-as-cross-stdenv (via
            #                          replaceCrossStdenv + cosmoOverlay)
            # The applyPatches step registers `cosmo` as a kernel + example
            # crossSystem in nixpkgs (see ./cosmo-lib-systems.patch). The
            # overlay self-guards on `isCosmo` so it's a no-op for
            # pkgsCross.mingwW64; `replaceCrossStdenv` likewise guards
            # before swapping in cosmocc. Net effect: vanilla mingw drvs
            # are unchanged, cosmo drvs are routed through cosmocc.
            windowsPkgs =
              let
                basePkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
                nixpkgsPatched = basePkgs.applyPatches {
                  name = "nixpkgs-cosmo";
                  src = nixpkgs.outPath;
                  patches = [ ./cosmo-lib-systems.patch ];
                };
                # Pass fixLib so cosmo overlay fragments can call
                # `lib.withAliases` (defined in nix-lib's lib).
                cosmoOverlay = import ./cosmo { lib = nixpkgs.lib // lib; };
              in
              import nixpkgsPatched {
                system = "x86_64-linux";
                overlays = [ cosmoOverlay ];
                config = {
                  allowUnsupportedSystem = true;
                  replaceCrossStdenv = { buildPackages, baseStdenv }:
                    if baseStdenv.hostPlatform.isCosmo or false
                    then
                      let
                        cs = import ./cosmocc.nix { pkgs = buildPackages; };
                        wiring = cs.mkCrossWiring {
                          inherit buildPackages baseStdenv;
                          targetArch = baseStdenv.hostPlatform.parsed.cpu.name;
                          targetPrefix = "${baseStdenv.hostPlatform.config}-";
                        };
                      in
                      wiring.stdenv
                    else baseStdenv;
                };
              };
            windowsRawBuild =
              if windowsBuild != null then windowsBuild
              else if windowsCosmo then (pkgs: (cosmoStaticCross pkgs).${pkgsAttr})
              else (pkgs: (mingwStaticCross pkgs).${pkgsAttr});
            # Man source for the windows/cosmo binary. The mingw/cosmo cross
            # build ships no man, so embed the (OS-independent, version-locked)
            # pages from the regular x86_64-linux build of the same attr. Pick
            # its `man` output when split, else `out` (man-in-out). null when
            # the attr doesn't exist or has no man → withMan skips gracefully.
            winManNixpkgs = nixpkgs.legacyPackages.${"x86_64-linux"};
            # `winManRoot` (package opt-in) wins: embed exactly the curated set
            # the package supplies. Otherwise fall back to the nixpkgs graft.
            winManSrc =
              if winManRoot != null then winManRoot
              else let p = winManNixpkgs.${pkgsAttr} or null;
                   in if p == null then null else (p.man or p.out or p);
            windowsBase = dropSharedLibs (applyOptSsp (windowsRawBuild windowsPkgs));
            windowsWithMan =
              if embedMan && winManSrc != null
              then withMan windowsPkgs { primary = binName; manRoot = "${winManSrc}"; } windowsBase
              else windowsBase;
            # Trim cosmo's unused `.symtab.amd64` (no-op on mingw). Runs after
            # withMan so the man block is already embedded.
            windowsTrimmed = withCosmoStrip windowsPkgs { primary = binName; } windowsWithMan;
            windowsPkg = strippedOrJoined windowsPkgs name windowsTrimmed;

            # `linuxOnly` drops every Darwin attr from `packages.<sys>` so
            # action-build's auto-discovered matrix doesn't include darwin
            # runners. Used for packages whose nixpkgs `meta.platforms`
            # excludes darwin entirely (kmod, util-linux, shadow,
            # procps-ng, iproute2 — anything that talks to Linux-only
            # kernel APIs).
            wantsNative = system: nativeBuild && !(linuxOnly && isDarwinSys system);
          in
          {
            packages = forAllNative (system:
              let pkgs = nixpkgsFor.${system}; in
              nixpkgs.lib.optionalAttrs (wantsNative system) { default = stripped pkgs; }
              // nixpkgs.lib.optionalAttrs (wantsNative system && system == "aarch64-darwin") {
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
                # armv7l-hf-multiplatform = armv7l-unknown-linux-musleabihf,
                # hardware float (VFPv3) + hardware 64-bit atomics
                # (LDREXD/STREXD). Covers Pi 2/3/4 in 32-bit mode,
                # BeagleBoneBlack, Odroid, and the dominant ARM 32-bit
                # hardware that runs Linux today. Matches the Rust
                # ecosystem convention (ripgrep/fd/bat use armv7l in
                # this slot) and the CI runner (ubuntu-24.04-arm).
                #
                # Trade-off: drops armv6 baseline (Pi 1 / Zero / Zero W).
                # Worth it because anything pulling in 64-bit atomics
                # (libssh2, glib ≥ 2.68, any modern threading wrapper)
                # fails to link on armv6 with __atomic_*_8 undefined,
                # since musl doesn't ship libatomic in pkgsStatic.
                "linux-armv7l" = stripped pkgs.pkgsCross.armv7l-hf-multiplatform;
              }
              // nixpkgs.lib.optionalAttrs (windowsEnabled && system == "x86_64-linux") {
                "windows-x86_64" = windowsPkg;
              });

            apps = forAllNative (system:
              nixpkgs.lib.optionalAttrs (wantsNative system) {
                default = {
                  type = "app";
                  program = "${self.packages.${system}.default}/bin/${binName}";
                };
              });

            # Read by unpins/action-build to drive CI config.
            manifest = {
              inherit name package_data bootstrap_naming own_software nativeBuild;
              # `smoke` is null when the caller didn't opt in; otherwise
              # a list of CLI args. JSON-encoded into the matrix to let
              # build.yml run `<bin> <args>` after each build.
              smoke = if smoke == null then null else smoke;
              # Optional grep-E pattern that must match the smoke command's
              # combined stdout+stderr. Catches "Unknown option" false-pass.
              smoke_pattern = if smokePattern == null then null else smokePattern;
            };
          };

        # mkPkgsLTO: pkgsStatic with a chain-wide LTO overlay. Every drv in
        # the closure rebuilds with -flto + gcc-ar + --gc-sections. Stack
        # protector kept via -Wl,-u,__stack_chk_fail. See ./lto.nix.
        # Consumed by mkStandaloneFlake when `lto = true`.
        mkPkgsLTO = import ./lto.nix { inherit nixpkgs appendCFlags; };

        # Native cosmoStdenv. Used by playground/{bash,coreutils,dash,links} for
        # in-tree builds against the `$COSMOS` shared prefix. The full result is
        # `stdenv // { cosmocc, cosmoCCUnwrapped, cosmoBintoolsUnwrapped,
        # platformBits, mkCrossWiring, version }` — consumers commonly want
        # `cosmoStdenv.mkDerivation` and `cosmoStdenv.platformBits`.
        cosmoStdenv = pkgs: import ./cosmocc.nix { inherit pkgs; };

        # `cosmoStaticCross pkgs` — fully symmetric with `pkgs.pkgsCross.mingwW64`
        # and `pkgs.pkgsStatic`: takes a build-host pkgs set (where cosmo wiring
        # was registered, e.g. mkStandaloneFlake's `windowsPkgs`) and returns
        # the cosmo cross pkgs set. Per-binary quirks live in the consumer's
        # `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }`.
        #
        # Cosmo is now a first-class nixpkgs cross target: `cosmo-lib-systems.patch`
        # registers the kernel + an `examples.cosmo` crossSystem, and
        # `windowsPkgs` is built with the cosmoOverlay + `replaceCrossStdenv`
        # guarded on `isCosmo`. The cross-arch story (aarch64-cosmo from
        # x86_64-linux) still needs a buildPackages.pkgsCross stanza — not
        # exposed yet because no catalog package needs it.
        cosmoStaticCross = pkgs: pkgs.pkgsCross.cosmo;

      };

      # Per-target fixes, auto-loaded from sibling directories.
      # See lib.mkStandaloneFlake and lib.mingwStaticCross for how they're consumed.
      # Fix files use nixpkgs.lib for stdlib (hasSuffix, filterAttrs, …) AND our
      # helpers (withDepsSharedPruned, mingwStaticCross, …) — fuse both into one
      # `lib` for them so they can write `lib.X` uniformly.
      #
      # `nativeFixes` is re-exposed inside the lib seen by fix files (and by
      # consumer `build` closures via `unpins-lib.lib.nativeFixes.<dep>`) so a
      # downstream consumer can reuse a library override (e.g. tmux's `build`
      # closure calls `lib.nativeFixes.libevent`). Safe under nix laziness
      # because cross-fix references only resolve when the consumer calls
      # the function with `pkgs`, not at top-level evaluation.
      fixLibBase = nixpkgs.lib // lib;
      nativeFixes = import ./native-overlay { lib = fixLibBase // { inherit nativeFixes; }; };
      mingwOverlayFixes = import ./mingw-overlay { lib = fixLibBase; };
    in
    {
      lib = lib // { inherit nativeFixes; };
    };
}
