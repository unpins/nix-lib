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
      # Darwin "almost-static" pkgs set. pkgsStatic doesn't work on
      # Darwin (libSystem must stay dynamic, but pkgsStatic adds
      # `-static` LDFLAG that breaks autoconf link probes). Instead
      # we use the regular darwin pkgs and patch individual libraries
      # whose default build leaves a .dylib that the linker would
      # pick over the .a.
      #
      # Each override below targets a library whose static-only knob
      # differs from the autoconf default (so staticOnlyAuto silently
      # fails). Grows as we hit new cases. Use in the darwin branch
      # of standalone flakes (htop, tmux, vim, …); linux/cross-mingw
      # keep using pkgsStatic.
      # ---------------------------------------------------------------

      pkgsDarwinStatic = pkgs: pkgs.appendOverlays [
        # ncurses knob is --with-shared / --without-shared, not the
        # autoconf default --enable-shared / --disable-shared.
        # nixpkgs maps `enableStatic = true` to --without-shared.
        (_: prev: {
          ncurses = prev.ncurses.override { enableStatic = true; };
        })
      ];

      # ---------------------------------------------------------------
      # Per-library "slim" overlays. Each removes propagated bloat or
      # auxiliary tools we don't ship in a standalone-binary package.
      # They're functions `pkgs -> pkgs` so consumers can compose them
      # by chaining (e.g. `slimLmSensors pkgs |> pkgsDarwinStatic` if
      # ever needed). Grows as we hit packages with similar issues.
      # ---------------------------------------------------------------

      # lm_sensors propagates perl + bash because sensors-detect (a
      # Perl script) needs them, and ships that script + a config
      # converter in $out/bin. Anything that links libsensors but
      # doesn't ship the userland tools (htop, glances, conky, …)
      # wants those gone.
      slimLmSensors = pkgs: pkgs.appendOverlays [
        (_: prev: {
          lm_sensors = prev.lm_sensors.overrideAttrs (old: {
            propagatedBuildInputs = prev.lib.filter
              (p: !builtins.elem (p.pname or "") [ "perl" "bash" ])
              (old.propagatedBuildInputs or []);
            postInstall = (old.postInstall or "") + ''
              rm -f $out/bin/sensors-detect $out/bin/sensors-conf-convert
              rm -f $out/sbin/sensors-detect $out/sbin/sensors-conf-convert
            '';
          });
        })
      ];

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
      # `binName` when they differ. Override `build` for darwin dep
      # gymnastics; the default `pkgs.pkgsStatic.${name}` is fine for
      # everything with no autoconf link probes.
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
          rawBuild = if build == null then (pkgs: pkgs.pkgsStatic.${name}) else build;
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
