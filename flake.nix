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
        # Most packages need `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` because their
        # `meta.platforms` doesn't list cosmo.
        mkPkgsCosmo = { system ? "x86_64-linux" }:
          let
            basePkgs = nixpkgs.legacyPackages.${system};
            nixpkgsPatched = basePkgs.applyPatches {
              name = "nixpkgs-cosmo";
              src = nixpkgs.outPath;
              patches = [ ./cosmo-lib-systems.patch ];
            };
            cosmoOverlay = import ./cosmo { inherit (nixpkgs) lib; };
          in
          import nixpkgsPatched {
            inherit system;
            crossSystem = {
              config = "x86_64-unknown-cosmo-gnu";
              libc = null;
            };
            overlays = [ cosmoOverlay ];
            config.replaceCrossStdenv = { buildPackages, baseStdenv }:
              let
                cs = import ./cosmocc.nix { pkgs = buildPackages; };
                wiring = cs.mkCrossWiring {
                  inherit buildPackages baseStdenv;
                  targetPrefix = "x86_64-unknown-cosmo-gnu-";
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
