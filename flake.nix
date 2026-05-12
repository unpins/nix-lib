{
  description = "Shared Nix helpers for unpins/* packages";

  # nixpkgs is bundled so packages that consume `mkStandaloneFlake`
  # don't have to declare it themselves; bumping nixpkgs across all
  # unpins/* becomes a one-line change here. Consumers that need
  # their own pin can still override via `inputs.unpins-lib.inputs.nixpkgs.follows = "nixpkgs"`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }: {
    # Helpers exposed as a flat attrset. Consumers add this flake as
    # an input and use `unpins-lib.lib`.
    lib = rec {
      # ---------------------------------------------------------------
      # System lists shared across unpins/* flakes.
      #
      # `nativeSystems` is the canonical list of native targets every
      # unpins package supports. Editing this list propagates to every
      # consumer (e.g. adding `riscv64-linux` becomes a one-line change
      # instead of N).
      #
      # `forAllNative f` returns `{ <system> = f system; ... }` over
      # `nativeSystems`. Implemented in pure nix (no `lib` import) so
      # nix-lib stays nixpkgs-agnostic.
      # ---------------------------------------------------------------

      nativeSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllNative = f:
        builtins.listToAttrs
          (map (sys: { name = sys; value = f sys; }) nativeSystems);

      # ---------------------------------------------------------------
      # Static-only build-system knobs.
      #
      # The unifying insight: ffmpeg-class consumers pass `-static`
      # to ld via `--extra-ldflags=-static` (or equivalent), which
      # makes the linker prefer `.a` over `.dll.a`. Producers just
      # need to ensure `.a` exists in the lib output.
      #
      # Each helper handles one build system. Cache-aware variants
      # (no-op when the consumer's pkgs is already pkgsStatic) live
      # in `keepStatic*` below.
      # ---------------------------------------------------------------

      # Autotools: --enable-static + --disable-shared. dontDisableStatic
      # tells nixpkgs not to delete .a in the strip phase.
      staticOnlyAuto = drv: drv.overrideAttrs (old: {
        dontDisableStatic = true;
        configureFlags = (old.configureFlags or [])
          ++ [ "--enable-static" "--disable-shared" ];
      });

      # Meson: default_library=static. Don't use 'both' under
      # pkgsStatic — its toolchain can't link shared objects
      # (crtbeginT.o R_X86_64_32 against hidden symbol error).
      staticOnlyMeson = drv: drv.overrideAttrs (old: {
        mesonFlags = (old.mesonFlags or [])
          ++ [ "-Ddefault_library=static" ];
      });

      # CMake: BUILD_SHARED_LIBS=OFF. Some projects ignore this and
      # have their own option (e.g. openapv: OAPV_BUILD_SHARED_LIB).
      # Inspect the project's CMakeLists when this isn't enough.
      staticOnlyCmake = extraFlags: drv: drv.overrideAttrs (old: {
        cmakeFlags = (old.cmakeFlags or [])
          ++ [ "-DBUILD_SHARED_LIBS=OFF" ] ++ extraFlags;
      });

      # ---------------------------------------------------------------
      # Cache-aware wrappers. Use these when the same code path runs
      # for both pkgsStatic (where libs already build static-only —
      # overriding would bust cache.nixos.org) and cross-mingw
      # (default shared, override required).
      # ---------------------------------------------------------------

      keepStaticAuto = pkgs: drv:
        if pkgs.stdenv.hostPlatform.isStatic or false
        then drv else staticOnlyAuto drv;

      keepStaticMeson = pkgs: drv:
        if pkgs.stdenv.hostPlatform.isStatic or false
        then drv else staticOnlyMeson drv;

      keepStaticCmake = pkgs: extraFlags: drv:
        if pkgs.stdenv.hostPlatform.isStatic or false
        then drv else staticOnlyCmake extraFlags drv;

      keepStaticZlib = pkgs: drv:
        if pkgs.stdenv.hostPlatform.isStatic or false
        then drv else drv.override { shared = false; };

      # ---------------------------------------------------------------
      # Per-package fixes applied to pkgsStatic-<name> derivations.
      #
      # Why not an overlay? `pkgs.appendOverlays` (and even
      # `pkgsStatic.appendOverlays`) invalidates `pkgsBuildHost.stdenv`
      # → cascade rebuild of compiler-rt-libc-static, ninja, python3
      # in pkgsStatic-darwin (none of which are in cache.nixos.org for
      # that variant; Hydra only builds pkgsStatic-linux). 30-60 min
      # of darwin CI just to add `--enable-static` to a single
      # nativeBuildInput.
      #
      # `drv.override` and `drv.overrideAttrs` applied per-package
      # don't touch the package set — they produce a new drv whose
      # build inputs are *still* the original cached pkgsStatic
      # stdenv. The drv itself rebuilds (input hash changed), but
      # everything below it (toolchain) stays cached.
      #
      # `applyPackageFix pkgs name drv` returns `drv` with the
      # adjustments needed for `name`. Add a branch when adopting a
      # new package whose pkgsStatic build is broken on some host.
      # ---------------------------------------------------------------

      applyPackageFix = pkgs: name: drv:
        let
          p = pkgs.pkgsStatic;

          # lm_sensors propagates perl + bash for sensors-detect (a
          # Perl script we don't ship) and installs the script in
          # $out/bin. Trim both.
          slimLmSensors = ls: ls.overrideAttrs (old: {
            propagatedBuildInputs = p.lib.filter
              (i: !builtins.elem (i.pname or "") [ "perl" "bash" ])
              (old.propagatedBuildInputs or [ ]);
            postInstall = (old.postInstall or "") + ''
              rm -f $out/bin/sensors-detect $out/bin/sensors-conf-convert
              rm -f $out/sbin/sensors-detect $out/sbin/sensors-conf-convert
            '';
          });

          # htop's own configure.ac interprets `--enable-static` as
          # "pass -static globally to the linker" (no libtool, no
          # autoconf standard handler). On darwin that breaks libSystem
          # link probes (libSystem.a doesn't exist) → configure fails
          # on `checking for access... no` / `NaN support... no`.
          # Filter those flags out of configureFlags so htop doesn't
          # auto-add -static. ncurses doesn't need a separate override
          # — pkgsStatic.ncurses in nixpkgs already passes
          # `--without-shared` (verified: its default configureFlags
          # start with --without-shared, and its output ships only .a).
          fixHtopDarwin = h: h.overrideAttrs (old: {
            configureFlags = p.lib.filter
              (f: f != "--enable-static" && f != "--disable-shared")
              (old.configureFlags or [ ]);
          });

          fixHtopLinux = h: h.override {
            lm_sensors = slimLmSensors p.lm_sensors;
          };
        in
        if name == "htop" then
          if p.stdenv.hostPlatform.isDarwin then fixHtopDarwin drv
          else if p.stdenv.hostPlatform.isLinux then fixHtopLinux drv
          else drv
        else drv;

      # ---------------------------------------------------------------
      # Cross-prefix discovery. Both pkgsStatic and pkgsCross.mingwW64
      # ship cc-wrappers with ONLY prefixed binaries (no plain `cc`
      # or `gcc`). Consumers like ffmpeg's configure can use
      # `--cross-prefix=<triple>-` so all `gcc`/`ld`/`ar`/etc calls
      # become `<triple>-gcc` etc.
      # ---------------------------------------------------------------

      crossPrefix = pkgs: "${pkgs.stdenv.hostPlatform.config}-";

      # ---------------------------------------------------------------
      # Cross-mingw single-binary wrapper. Forces --disable-shared
      # --enable-static at configure-time and -all-static at make-time.
      #
      # Why not pkgsCross.mingwW64.pkgsStatic.<pkg>? It regenerates the
      # host triple as `x86_64-w64-windows-gnu` (config.sub rejects),
      # and `crossSystem.isStatic = true` rebuilds the entire xgcc
      # without a binary cache hit.
      #
      # `staticDeps` is passed via .override so libtool sees the .a in
      # the dep's lib output (NOT applied as overlay — would touch the
      # toolchain, since gcc itself uses zlib/zstd → full xgcc rebuild).
      #
      # `filterConfigureFlag` lets consumers strip a flag the package
      # adds unconditionally (curl's --without-ssl when openssl=false).
      # ---------------------------------------------------------------

      mingwStandalone =
        { pkg
        , staticDeps ? {}
        , extraInputs ? []
        , extraConfigureFlags ? []
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
              ++ [ "--enable-static" "--disable-shared" ]
              ++ extraConfigureFlags;
            # -all-static is the libtool-aware flag that reaches the
            # final link stage and forces archive-only resolution.
            # Passing it to configure via NIX_LDFLAGS would break
            # autoconf's "C compiler works" probe — make-time only.
            makeFlags = (old.makeFlags or []) ++ [ "LDFLAGS=-all-static" ];
          } // extraOverrides old);

      # ---------------------------------------------------------------
      # Packaging: combine multi-output drv (bin + man + …) into one
      # store path, strip the binary, preserve passthru.
      # ---------------------------------------------------------------

      packageWithMan = pkgs: name: drv:
        let stripped = drv.overrideAttrs (_: { stripAllList = [ "bin" ]; });
        in pkgs.symlinkJoin {
          name = "${name}-${stripped.version}";
          paths = [ stripped.bin stripped.man ];
          passthru = { inherit (stripped) version pname; };
        };

      # ---------------------------------------------------------------
      # Standalone-binary flake template. Returns { packages, apps }
      # with the same shape every unpins/* small package uses:
      #   packages.<system>.default            = pkgsStatic build
      #   packages.aarch64-darwin."darwin-x86_64" = cross-built x86_64-darwin
      #   apps.<system>.default                = `nix run` entry
      #
      # `name` is the nixpkgs attribute and the resulting bin name. Use
      # `binName` when they differ. The default `build` is
      # `pkgs.pkgsStatic.${name}` passed through `applyPackageFix`, so
      # the pkgsStatic toolchain (stdenv, compiler-rt-static, …) stays
      # cached — only the package itself rebuilds with the fix.
      # ---------------------------------------------------------------

      mkStandaloneFlake =
        { self
        , name
        , build ? null
        , binName ? name
        , package_data ? true
        , bootstrap_naming ? false
        , own_software ? false
        }:
        let
          nixpkgsFor = forAllNative (system: import nixpkgs { inherit system; });
          rawBuild =
            if build == null
            then (pkgs: applyPackageFix pkgs name pkgs.pkgsStatic.${name})
            else build;
          stripped = pkgs: (rawBuild pkgs).overrideAttrs (_: { stripAllList = [ "bin" ]; });
        in {
          packages = forAllNative (system:
            let pkgs = nixpkgsFor.${system}; in
            { default = stripped pkgs; }
            // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
              "darwin-x86_64" = stripped pkgs.pkgsCross.x86_64-darwin;
            });

          apps = forAllNative (system: {
            default = {
              type = "app";
              program = "${self.packages.${system}.default}/bin/${binName}";
            };
          });

          # Read by unpins/action-build to drive CI config — keeps consumer
          # workflow files down to triggers + `secrets: inherit`.
          manifest = {
            inherit name package_data bootstrap_naming own_software;
          };
        };
    };
  };
}
