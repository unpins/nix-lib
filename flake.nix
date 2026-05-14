{
  description = "Shared Nix helpers for unpins/* packages";

  # Bundled so consumers don't redeclare; bump propagates to every unpins/*.
  # Override via `inputs.unpins-lib.inputs.nixpkgs.follows = "nixpkgs"`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      # Per-package fix registry. Name-keyed, with platform sub-keys:
      #   ${name}.native       : pkgs -> drv             -- terminal native (pkgsStatic)
      #   ${name}.mingw        : pkgs -> drv             -- terminal mingw cross
      #   ${name}.mingwOverlay : self -> super -> drv    -- transitive dep, consumed
      #                                                     by `mingwStaticCross`
      # Internal to `mingwStaticCross` and `mkStandaloneFlake`; not exposed at `lib.*`.
      fixes = {
        # darwin: htop's configure.ac treats `--enable-static` as "pass -static globally
        # to ld" (no libtool involved); libSystem.a doesn't exist → configure probes fail.
        # Filter the flag.
        # linux: htop's lm_sensors propagates perl+bash for sensors-detect (we don't
        # ship it). Slim both and rm the script.
        htop.native = pkgs:
          let p = pkgs.pkgsStatic; in
          if p.stdenv.hostPlatform.isDarwin then
            p.htop.overrideAttrs (old: {
              configureFlags = p.lib.filter
                (f: f != "--enable-static" && f != "--disable-shared")
                (old.configureFlags or [ ]);
            })
          else if p.stdenv.hostPlatform.isLinux then
            p.htop.override {
              lm_sensors = p.lm_sensors.overrideAttrs (old: {
                propagatedBuildInputs = p.lib.filter
                  (i: !builtins.elem (i.pname or "") [ "perl" "bash" ])
                  (old.propagatedBuildInputs or [ ]);
                postInstall = (old.postInstall or "") + ''
                  rm -f $out/bin/sensors-detect $out/bin/sensors-conf-convert
                  rm -f $out/sbin/sensors-detect $out/sbin/sensors-conf-convert
                '';
              });
            }
          else
            p.htop;

        # darwin: pkgsStatic.tmux's configure.ac passes `-static` globally → libSystem
        # link probe fails. Fall back to regular tmux with deps' shared libs pruned;
        # runtime closure ends up libSystem-only either way.
        #
        # Plus postPatch: tmux's configure.ac probes `b64_ntop` against -lresolv;
        # on darwin libresolv provides it so tmux links libresolv.9.dylib. We only
        # want libSystem in the binary, so disable that probe — tmux falls back to
        # its bundled compat/base64.c.
        #
        # Second patch: darwin's <resolv.h> macros-rename `b64_ntop` to
        # `res_9_b64_ntop`. compat.h `#undef`s these macros at call sites, but
        # compat/base64.c (the bundled implementation) still picks them up and
        # ends up defining `_res_9_b64_ntop`, leaving `_b64_ntop` undefined.
        # Drop the unused `#include <resolv.h>` from compat/base64.c so the
        # function names match across translation units.
        tmux.native = pkgs:
          let p = pkgs.pkgsStatic; in
          if p.stdenv.hostPlatform.isDarwin
          then (lib.withDepsSharedPruned pkgs pkgs.tmux).overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace configure.ac \
                --replace-fail 'LIBS="$OLD_LIBS -lresolv"' 'LIBS="$OLD_LIBS"'
              substituteInPlace compat/base64.c \
                --replace-fail '#include <resolv.h>' ""
            '';
          })
          else p.tmux;

        # Three things upstream nixpkgs doesn't do for jq on mingw:
        # - winpthreads in buildInputs (mingw-w64 ships it separately; jq #includes <pthread.h>).
        # - LDFLAGS=-all-static: windows.pthreads ships .a + .dll.a; without it libtool picks
        #   .dll.a and the DLL-link hook copies libwinpthread.dll next to jq.exe.
        # - postFixup: nixpkgs jq.nix hard-codes `$bin/bin/jq`; on mingw it's jq.exe.
        jq.mingw = pkgs:
          let cross = lib.mingwStaticCross pkgs; in
          cross.jq.overrideAttrs (old: {
            buildInputs = (old.buildInputs or []) ++ [ cross.windows.pthreads ];
            makeFlags = (old.makeFlags or []) ++ [ "LDFLAGS=-all-static" ];
            postFixup = ''
              remove-references-to \
                -t "$dev" -t "$man" -t "$doc" \
                "$bin/bin/jq.exe"
            '';
          });

        # libidn2 ships idn2.exe. Without -all-static, idn2.exe resolves -liconv via
        # dll.a and pulls libiconv-2.dll into its closure → poisons curl transitively.
        # Also propagate libunistring (nixpkgs lists it as plain buildInput; strictDeps
        # consumers don't see -L).
        libidn2.mingwOverlay = self: super:
          super.libidn2.overrideAttrs (old: {
            makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
            propagatedBuildInputs = (old.propagatedBuildInputs or [ ])
              ++ [ self.libunistring ];
          });

        # libpsl:
        # - Default .pc puts libidn2/libunistring/libiconv in Libs.private. Curl's
        #   pkg-config probe uses --libs-only-l which only honors Libs:. Promote them,
        #   ordered consumer-before-provider for single-pass static linking.
        # - Propagate libunistring/libiconv so strictDeps consumers get -L paths.
        # - `.override { libidn2 = ... }` re-threads the overlay'd libidn2 (overrideAttrs
        #   alone doesn't re-evaluate the call's args).
        libpsl.mingwOverlay = self: super:
          (super.libpsl.override {
            inherit (self) libidn2;
          }).overrideAttrs (old: {
            propagatedBuildInputs = (old.propagatedBuildInputs or [ ])
              ++ [ self.libunistring self.libiconv ];
            postFixup = (old.postFixup or "") + ''
              pc="$dev/lib/pkgconfig/libpsl.pc"
              if [ -f "$pc" ]; then
                sed -i '/^Libs:/c\
Libs: -L''${libdir} -L${self.libunistring}/lib -L${self.libiconv}/lib -lpsl -lidn2 -lunistring -liconv -lws2_32
' "$pc"
              fi
            '';
          });
      };

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
      # which apple-sdk's atf needs). So `drv.override` / `.overrideAttrs` inside
      # `fixes` entries is the only path keeping both the cached toolchain AND
      # autotools-native-mode configure runs.

      # Rebuild `drv` with every dep in `drv.override.__functionArgs` swapped for
      # its `pkgsStatic` counterpart (.a-only, no shared libs at all), falling back
      # to `dropSharedLibs` on the regular version when no pkgsStatic variant exists.
      #
      # Used by `fixes.tmux.native` on darwin: pkgsStatic.tmux itself fails to link
      # (configure.ac passes `-static` globally → libSystem probe fails), so we keep
      # regular tmux but swap its deps for the static variants. Preferring pkgsStatic
      # over postFixup-delete dodges the dyld-at-build-time pitfall (ncurses ships
      # `tic`/`infocmp` binaries dynamically linked to `libncursesw.dylib`; deleting
      # the dylib breaks tmux-terminfo, which `tic`s at build time).
      withDepsSharedPruned = pkgs: drv:
        let
          fnArgs = drv.override.__functionArgs or {};
          isPrunableDrv = v:
            builtins.isAttrs v
            && (v.type or null) == "derivation"
            && v ? overrideAttrs;
          pruneOne = name:
            let
              staticDep  = pkgs.pkgsStatic.${name} or null;
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
        in drv.override overrides;

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
      #
      # Why not `pkgsCross.mingwW64.pkgsStatic`? It re-instantiates nixpkgs with
      # `crossSystem.isStatic = true` → changes windows.mingw_w64 / mcfgthread
      # configureFlags → cross gcc rebuilds against them → ~30 min toolchain rebuild
      # for byte-identical output. The fudge sidesteps this.
      mingwStaticCross = pkgs: pkgs.pkgsCross.mingwW64.appendOverlays [
        (selfPkgs: superPkgs:
          if superPkgs.stdenv.hostPlatform.isMinGW or false
          then
            let
              base = superPkgs.stdenvAdapters.makeStaticLibraries superPkgs.stdenv;
              # `fixes.<name>.mingwOverlay` entries become overlay pieces at `<name>`.
              # Curl & friends transitively see the fixed versions via `cross.<dep>`
              # references — no caller-side lookup.
              mingwOverlayEntries = nixpkgs.lib.mapAttrs
                (_: e: e.mingwOverlay selfPkgs superPkgs)
                (nixpkgs.lib.filterAttrs (_: e: e ? mingwOverlay) fixes);
            in {
              stdenv = base // {
                hostPlatform = base.hostPlatform // { isStatic = true; };
              };
            } // mingwOverlayEntries
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
        , staticDeps ? {}
        , extraInputs ? []
        , extraConfigureFlags ? []
        , extraCFlags ? []
        , filterConfigureFlag ? (_: true)
        , extraOverrides ? (_: {})
        }:
        let
          overridden = if staticDeps == {} then pkg else pkg.override staticDeps;
        in
        overridden.overrideAttrs (old:
          {
            stripAllList = [ "bin" ];
            buildInputs = (old.buildInputs or []) ++ extraInputs;
            configureFlags =
              (builtins.filter filterConfigureFlag (old.configureFlags or []))
              ++ extraConfigureFlags;
            # Make-time only. Passing via NIX_LDFLAGS at configure breaks autoconf's
            # "C compiler works" probe.
            makeFlags = (old.makeFlags or []) ++ [ "LDFLAGS=-all-static" ];
          }
          // (nixpkgs.lib.optionalAttrs (extraCFlags != []) {
            # mingw headers (nghttp2, libpsl, libcurl, ...) default to
            # `__declspec(dllimport)`. Static consumers need *_STATICLIB defined or
            # the link leaves `__imp_*` unresolved.
            env = (old.env or {}) // {
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
        in pkgs.symlinkJoin {
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
      # `name` is looked up in `fixes.${name}.{native,mingw}` (see registry at top);
      # falls back to `pkgs.pkgsStatic.${name}` / `(mingwStaticCross pkgs).${name}`.
      # Consumers wanting full control pass `build` / `windowsBuild` directly.
      # `binName` overrides when bin name ≠ name. `nativeBuild = false` → windows-only
      # (e.g. gvim: static GTK infeasible on linux, MacVim is its own .app bundle).
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

          # Resolve `fixes.${name}.${platform}` safely; falls back to `default` when
          # name isn't registered or doesn't define this platform.
          lookupFix = platform: default:
            (fixes.${name} or {}).${platform} or default;

          # dropSharedLibs is a no-op on isStatic outputs (default pkgsStatic) but
          # normalizes any registry entry that fell back to non-static deps (e.g.
          # tmux on darwin).
          rawBuild =
            if build != null then build
            else lookupFix "native" (pkgs: pkgs.pkgsStatic.${name});
          stripped = pkgs: strippedOrJoined pkgs name (dropSharedLibs (rawBuild pkgs));

          # Windows runs on x86_64-linux runners. `allowUnsupportedSystem` because
          # most nixpkgs `meta.platforms` exclude mingw → cross-built drv would be
          # filtered out. `windows = true` → registry lookup. `windowsBuild` → consumer-
          # supplied from scratch (curl Schannel, vim/gvim Make_ming.mak).
          windowsEnabled = windows || windowsBuild != null;
          windowsPkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnsupportedSystem = true;
          };
          windowsRawBuild =
            if windowsBuild != null then windowsBuild
            else lookupFix "mingw" (pkgs: (mingwStaticCross pkgs).${name});
          windowsPkg = strippedOrJoined windowsPkgs name
            (dropSharedLibs (windowsRawBuild windowsPkgs));
        in {
          packages = forAllNative (system:
            let pkgs = nixpkgsFor.${system}; in
            nixpkgs.lib.optionalAttrs nativeBuild { default = stripped pkgs; }
            // nixpkgs.lib.optionalAttrs (nativeBuild && system == "aarch64-darwin") {
              "darwin-x86_64" = stripped pkgs.pkgsCross.x86_64-darwin;
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
    };
  in { inherit lib; };
}
