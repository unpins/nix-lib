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
      # Per-package fixes applied on top of the static package set
      # returned by `staticPkgsForSystem` (pkgsStatic on linux,
      # `darwinStaticCross` on darwin, `mingwStaticCross` on mingw).
      #
      # These are `drv.override` / `drv.overrideAttrs` applied to a
      # single drv at a time — they produce a new drv but don't touch
      # the package set, so the cached static stdenv stays referenced
      # verbatim and only the package itself rebuilds.
      #
      # `applyPackageFix pkgs name drv` returns `drv` with the
      # adjustments needed for `name`, where `pkgs` is the static
      # package set the drv was pulled from. Add a branch when
      # adopting a new package whose static build is broken on some
      # host.
      # ---------------------------------------------------------------

      applyPackageFix = pkgs: name: drv:
        let
          # `p` aliases the static package set the caller passed in.
          # Use `p.lib.*` for nixpkgs lib helpers, `p.<attr>` to refer
          # to other packages in the same set (e.g. lm_sensors below).
          p = pkgs;

          # Whether the caller's stdenv already produces static-only
          # libraries by default (pkgsStatic on Linux). When true, the
          # lib-level static knob branches below are no-ops: the
          # underlying drv already ships only `.a`. On darwin/mingw
          # the static set is a `makeStaticLibraries`-adapter overlay
          # whose hostPlatform is NOT marked `isStatic`, so the lib
          # fixes do still need to fire there.
          isStatic = pkgs.stdenv.hostPlatform.isStatic or false;

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

          # tmux: same libSystem problem as htop. configure.ac
          # interprets `--enable-static` as a global `-static` to the
          # linker, which fails libSystem probes (libSystem.a doesn't
          # exist on darwin). `darwinStaticCross` injects both flags
          # via `makeStaticLibraries`; filter them out so tmux's
          # configure falls back to default linking. tmux's deps
          # (ncurses, libevent, utf8proc) still come from the
          # static-adapter stdenv, so they ship only `.a` and the
          # final tmux binary ends up statically linked anyway.
          fixTmuxDarwin = t: t.overrideAttrs (old: {
            configureFlags = p.lib.filter
              (f: f != "--enable-static" && f != "--disable-shared")
              (old.configureFlags or [ ]);
          });

          # ----------------------------------------------------------
          # Library knobs that mingwStaticCross's makeStaticLibraries
          # adapter doesn't reach. Each branch is a no-op when the
          # underlying stdenv is already pkgsStatic (`isStatic`), so
          # consumers can call this unconditionally regardless of
          # whether `pkgs` is pkgsStatic or mingwStaticCross.
          #
          # zlib: nixpkgs uses a custom builder that ignores
          # configureFlags/cmakeFlags/mesonFlags. Its only static
          # knob is `shared = !isStatic`. Under mingw cross
          # (isStatic = false) it ships only .dll + .dll.a, not .a.
          # Force `shared = false`.
          fixZlib = z: if isStatic then z else z.override { shared = false; };

          # zstd: cmake, but its CMakeLists uses its own switches —
          # `ZSTD_BUILD_SHARED` and `ZSTD_BUILD_STATIC` — and silently
          # ignores the generic `BUILD_SHARED_LIBS` that the adapter
          # injects. Drive both via the package-level `static` knob.
          fixZstd = z: if isStatic then z else z.override { static = true; };

          # x264: configure is a hand-rolled shell+perl script (not
          # autoconf), so it doesn't recognize the adapter-injected
          # `--disable-shared`. Pass static flags it does understand.
          # Plus: x264.h decorates symbols with `__declspec(dllimport)`
          # when `X264_API_IMPORTS` is set, and nixpkgs leaves it in
          # the .pc — so consumers (ffmpeg) end up looking for
          # `__imp_x264_*` against the static .a. Strip it.
          fixX264 = x: x.overrideAttrs (old: {
            configureFlags = (old.configureFlags or [ ])
              ++ pkgs.lib.optionals (!isStatic)
                [ "--enable-static" "--disable-shared" "--enable-pic" ];
            postFixup = (old.postFixup or "") + ''
              for d in "$dev" "$out"; do
                pc="$d/lib/pkgconfig/x264.pc"
                [ -f "$pc" ] && sed -i 's| -DX264_API_IMPORTS||g' "$pc" || true
              done
            '';
          });

          fixed =
            if name == "htop" then (
              if p.stdenv.hostPlatform.isDarwin then fixHtopDarwin drv
              else if p.stdenv.hostPlatform.isLinux then fixHtopLinux drv
              else drv
            )
            else if name == "tmux" && p.stdenv.hostPlatform.isDarwin then fixTmuxDarwin drv
            else if name == "zlib" then fixZlib drv
            else if name == "zstd" then fixZstd drv
            else if name == "x264" then fixX264 drv
            else drv;
        in
          fixed;

      # ---------------------------------------------------------------
      # Windows static cross set.
      #
      # `mingwStaticCross pkgs` returns `pkgs.pkgsCross.mingwW64` with
      # an overlay that swaps `stdenv` for `makeStaticLibraries stdenv`
      # — but ONLY when the evaluated package set's host is mingw.
      # That conditional is load-bearing: `pkgsBuildHost` of the cross
      # set is linux (the build platform), so the overlay's then-branch
      # never fires there and `pkgsBuildHost.stdenv` keeps its
      # cache.nixos.org hash. Same goes for `cc`/`bintools` inside the
      # mingw stdenv — `makeStaticLibraries` only wraps mkDerivation,
      # leaving cc untouched, so the cached cross gcc stays referenced
      # verbatim and never rebuilds.
      #
      # The end result mirrors `pkgs.pkgsStatic` on linux/darwin: every
      # package transparently builds static archives without consumer
      # configuration. Problem packages get a per-package branch in
      # `applyMingwFix` below.
      #
      # Why not `pkgsCross.mingwW64.pkgsStatic`? It re-instantiates
      # with `crossSystem.isStatic = true`, picking
      # mingw-w64-static/mcfgthread-static and rebuilding gcc against
      # those — even though the static variants of those libs produce
      # byte-identical outputs to the shared variants. ~30 min of
      # toolchain rebuild that this overlay-based set sidesteps.
      # ---------------------------------------------------------------

      mingwStaticCross = pkgs: pkgs.pkgsCross.mingwW64.appendOverlays [
        (self: super:
          if super.stdenv.hostPlatform.isMinGW or false
          then { stdenv = super.stdenvAdapters.makeStaticLibraries super.stdenv; }
          else { })
      ];

      # ---------------------------------------------------------------
      # Darwin static cross set. Same idea as `mingwStaticCross`: wrap
      # stdenv with `makeStaticLibraries` so every package builds .a
      # archives without consumer configuration.
      #
      # Native darwin is special because `pkgs.appendOverlays` on a
      # non-cross set invalidates `pkgsBuildHost.stdenv` → cascade
      # rebuild of compiler-rt-static, ninja, python3 in pkgsStatic
      # variants that Hydra doesn't pre-build for darwin.
      #
      # The trick: nixpkgs decides "is this cross?" by comparing the
      # GNU triple (`stdenv.hostPlatform.config`) of build vs host,
      # NOT by comparing systems. Forcing a non-canonical config
      # string for the same system flips the package set into cross
      # mode. From there, `pkgsBuildHost` separates from `pkgs`, and
      # our overlay condition fires only on the host side. The
      # build-side toolchain (gcc/clang, cmake/ninja/python from
      # `pkgsBuildBuild`) stays cached; host-side compiler-rt and
      # libcxx do rebuild for the new triple — acceptable since they
      # cache in unpins.cachix.org after the first run.
      #
      # Config choice: `${cpu}-apple-darwin99`. The canonical native
      # darwin triples are `arm64-apple-darwin` (aarch64) and
      # `x86_64-apple-darwin` (x86_64); appending a fake macOS major
      # version `99` differs as a string without changing the parse
      # (kernel = "darwin", abi defaulted). Critically it stays
      # autotools-compatible: GNU `config.sub` accepts arbitrary
      # darwin version numbers, so packages like apple-sdk's `atf`
      # that validate triples via `config.sub` don't bail out. The
      # earlier attempt with `<cpu>-pc-darwin-unknown` failed config.sub
      # ("OS 'unknown' not recognized") even though nixpkgs parsed it.
      #
      # When the caller's pkgs is already a real cross set (e.g.
      # `pkgsCross.x86_64-darwin` from aarch64-darwin), the config
      # strings already differ, so we skip the re-import and just
      # append the overlay.
      # ---------------------------------------------------------------

      darwinStaticCross = pkgs:
        let
          alreadyCross =
            pkgs.stdenv.hostPlatform.config != pkgs.stdenv.buildPlatform.config;
          cpu = if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
          customConfig = "${cpu}-apple-darwin99";
          base =
            if alreadyCross
            then pkgs
            else import nixpkgs {
              localSystem = {
                inherit (pkgs.stdenv.buildPlatform) system config;
              };
              crossSystem = {
                inherit (pkgs.stdenv.hostPlatform) system;
                config = customConfig;
              };
            };
        in
          base.appendOverlays [
            (self: super:
              if (super.stdenv.hostPlatform.isDarwin or false)
                && super.stdenv.hostPlatform.config != super.stdenv.buildPlatform.config
              then { stdenv = super.stdenvAdapters.makeStaticLibraries super.stdenv; }
              else { })
          ];

      # ---------------------------------------------------------------
      # Pick the right static-producing package set for the caller's
      # platform. Linux uses plain `pkgsStatic` (Hydra-cached). Darwin
      # uses `darwinStaticCross` (fake-cross config trick). MinGW
      # callers go through `applyMingwFix` instead, not this helper.
      # ---------------------------------------------------------------

      staticPkgsForSystem = pkgs:
        if pkgs.stdenv.hostPlatform.isDarwin or false
        then darwinStaticCross pkgs
        else pkgs.pkgsStatic;

      # ---------------------------------------------------------------
      # Per-package fixes applied on top of `mingwStaticCross`.
      #
      # Most packages get the unmodified static-cross drv. Only
      # packages whose upstream nixpkgs definition assumes a non-mingw
      # target (filename suffix, runtime libs not in propagated inputs,
      # libtool not forcing `-all-static`, ...) need a branch here.
      # ---------------------------------------------------------------

      applyMingwFix = pkgs: name:
        let
          cross = mingwStaticCross pkgs;

          # jq:
          # - buildInputs += windows.pthreads. jq #includes <pthread.h>
          #   on mingw; mingw-w64 ships winpthreads as a separate
          #   package not in jq's default propagatedBuildInputs.
          # - makeFlags += LDFLAGS=-all-static so libtool's final link
          #   resolves only against `.a` archives. Without it,
          #   `windows.pthreads` ships both libwinpthread.a and
          #   libwinpthread.dll.a; the linker prefers the .dll.a and
          #   nixpkgs' DLL-link hook then copies the matching .dll
          #   next to jq.exe — failing the single-binary contract.
          # - postFixup: nixpkgs jq.nix hard-codes `$bin/bin/jq`; on
          #   mingw the file is jq.exe, so sed bails on no input.
          fixJq = j: j.overrideAttrs (old: {
            buildInputs = (old.buildInputs or []) ++ [ cross.windows.pthreads ];
            makeFlags = (old.makeFlags or []) ++ [ "LDFLAGS=-all-static" ];
            postFixup = ''
              remove-references-to \
                -t "$dev" -t "$man" -t "$doc" \
                "$bin/bin/${name}.exe"
            '';
          });

          raw = cross.${name};
          fixed = if name == "jq" then fixJq raw else raw;
        in
          fixed;

      # ---------------------------------------------------------------
      # Cross-prefix discovery. Both pkgsStatic and pkgsCross.mingwW64
      # ship cc-wrappers with ONLY prefixed binaries (no plain `cc`
      # or `gcc`). Consumers like ffmpeg's configure can use
      # `--cross-prefix=<triple>-` so all `gcc`/`ld`/`ar`/etc calls
      # become `<triple>-gcc` etc.
      # ---------------------------------------------------------------

      crossPrefix = pkgs: "${pkgs.stdenv.hostPlatform.config}-";

      # ---------------------------------------------------------------
      # Cross-mingw single-binary wrapper. Used by curl/ffmpeg/vim
      # consumed via `mkStandaloneFlake`'s `windowsBuild` arg for
      # packages whose Windows build needs more than the default
      # `mingwStaticCross.${name}` (e.g. Schannel for curl, from-source
      # mkDerivation for ffmpeg, Make_ming.mak for vim).
      #
      # Forces --disable-shared --enable-static at configure-time and
      # -all-static at make-time, so libtool resolves only `.a` and
      # nixpkgs' DLL-link hook doesn't copy DLLs next to the binary.
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
        let
          stripped = drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; });
          outs = stripped.outputs or [ "out" ];
          # jq-style drvs declare a dedicated `bin` output; bash/coreutils-style
          # drvs put binaries in `out`. Pick whichever holds the executables.
          primary = if builtins.elem "bin" outs then stripped.bin else stripped.out;
          hasMan = builtins.elem "man" outs;
        in pkgs.symlinkJoin {
          name = "${name}-${stripped.version}";
          paths = [ primary ] ++ nixpkgs.lib.optional hasMan stripped.man;
          passthru = { inherit (stripped) version pname; };
        };

      # ---------------------------------------------------------------
      # Strip-only for single-output drvs; symlinkJoin (bin + man) for
      # multi-output. Either way the resulting drv has a single output
      # so `nix build` creates the bare `result` symlink that
      # action-build's verify step looks for at `result/bin/<pkg>`.
      # Without this, multi-output packages like jq end up as
      # `result-bin`/`result-man` and the verify step bails on
      # `readlink -f result/bin/jq` returning empty.
      # ---------------------------------------------------------------
      strippedOrJoined = pkgs: name: drv:
        if (drv.outputs or [ "out" ]) == [ "out" ]
        then drv.overrideAttrs (_: { stripAllList = [ "bin" "out" ]; })
        else packageWithMan pkgs name drv;

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
        , windowsBuild ? null
        , binName ? name
        , windows ? false
        , package_data ? true
        , bootstrap_naming ? false
        , own_software ? false
        }:
        let
          nixpkgsFor = forAllNative (system: import nixpkgs { inherit system; });
          rawBuild =
            if build == null
            then (pkgs:
              let sp = staticPkgsForSystem pkgs;
              in applyPackageFix sp name sp.${name})
            else build;
          stripped = pkgs: strippedOrJoined pkgs name (rawBuild pkgs);

          # Windows build runs on x86_64-linux runners. allowUnsupportedSystem
          # because most nixpkgs `meta.platforms` lists exclude mingw,
          # so the cross-built drv would otherwise be filtered out.
          #
          # Two modes:
          #   - `windows = true` (default cross via nixpkgs attr): we use
          #     plain pkgsCross.mingwW64 (cached) and apply
          #     `makeStaticLibraries` as a stdenv adapter per-package —
          #     see `applyMingwFix` for the rationale.
          #   - `windowsBuild = pkgs: drv` (custom): consumer constructs
          #     the drv from scratch with full access to `windowsPkgs`
          #     (plain nixpkgs at x86_64-linux). Used by curl (Schannel
          #     + libpsl chain), ffmpeg (from-source mingw cross),
          #     vim (Make_ming.mak custom).
          windowsEnabled = windows || windowsBuild != null;
          windowsPkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnsupportedSystem = true;
          };
          windowsRaw =
            if windowsBuild != null
            then windowsBuild windowsPkgs
            else applyMingwFix windowsPkgs name;
          windowsPkg = strippedOrJoined windowsPkgs name windowsRaw;
        in {
          packages = forAllNative (system:
            let pkgs = nixpkgsFor.${system}; in
            { default = stripped pkgs; }
            // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
              "darwin-x86_64" = stripped pkgs.pkgsCross.x86_64-darwin;
            }
            // nixpkgs.lib.optionalAttrs (windowsEnabled && system == "x86_64-linux") {
              "windows-x86_64" = windowsPkg;
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
