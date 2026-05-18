# Cosmopolitan toolchain wiring.
#
# Migrated from the (now retired) cosmocc/ flake repo. Exposes:
#   - cosmocc                : raw $out from cosmocc.zip
#   - cosmoStdenv            : native stdenv with cc-wrapper around cosmocc
#   - cosmoCCUnwrapped       : single-arch cc dir w/ shims (gcc/cc/g++/c++/cpp)
#   - cosmoBintoolsUnwrapped : APE bintools shimmed for kernel exec
#   - platformBits           : apelink -V <bits> per OS
#   - mkCrossWiring          : helpers for mkPkgsCosmo (cross-stdenv injection)
#
# `pkgs` is the build-side nixpkgs (linux-gnu). Consumers either use cosmoStdenv
# directly (existing playground/{bash,coreutils,dash,links}) or feed mkCrossWiring
# into config.replaceCrossStdenv (new mkPkgsCosmo path).
{ pkgs }:

let
  inherit (pkgs) lib;

  version = "4.0.2";

  # Upstream mmap.c at the cosmocc tag we ship — fetched separately so we
  # can patch it without bundling 38 KB of cosmopolitan source in our repo.
  # The patch fixes the wine hang where cosmo's pickaddr loops forever on
  # STATUS_CONFLICTING_ADDRESSES; see cosmocc-wine-fix/.
  cosmoMmapSrc = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/jart/cosmopolitan/${version}/libc/intrin/mmap.c";
    hash = "sha256-xHsnD5UZCwpmPOtgWklpbXzDCFY2aVaY0YUkpTpb54k=";
  };

  # See docs/platforms/cosmocc.md for why dontPatchELF / dontStrip / etc. are
  # required on APE polyglots.
  cosmocc = pkgs.stdenvNoCC.mkDerivation {
    pname = "cosmocc";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://cosmo.zip/pub/cosmocc/cosmocc-${version}.zip";
      hash = "sha256-hbjDekBthi5latTsFL6fbOR0wbQ2uWFekaVSCKztP0Q=";
    };

    nativeBuildInputs = [ pkgs.unzip ];

    dontPatchELF = true;
    dontStrip = true;
    dontConfigure = true;
    dontBuild = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir -p $out
      unzip -q $src -d $out
      # Upstream zip ships cosmoranlib as 444 (not executable). Other cosmo*
      # fat scripts are 555. Normalize.
      chmod +x $out/bin/cosmoranlib

      # Patch libcosmo.a's mmap.o to fix the wine fixed-VA hang. The bug:
      # cosmo's pickaddr-then-retry loop on STATUS_CONFLICTING_ADDRESSES is
      # deterministic, so when wine puts ntdll inside cosmo's preferred VA
      # range, the loop never escapes. Patch leaves the failed range as a
      # ghost reservation; pickaddr then skips it. See the .patch file for
      # the full root-cause writeup. We rebuild mmap.o with the bundled
      # cosmocc itself (single command emits both x86_64 + .aarch64/),
      # then `ar r` swaps it into both libcosmo.a archives.
      mkdir -p $TMPDIR/cosmosrc/libc/intrin $TMPDIR/build/.aarch64
      cp ${cosmoMmapSrc} $TMPDIR/cosmosrc/libc/intrin/mmap.c
      chmod u+w $TMPDIR/cosmosrc/libc/intrin/mmap.c
      patch -p1 -d $TMPDIR/cosmosrc < ${./cosmocc-wine-fix/wine-fixed-addr-leak.patch}
      ( cd $TMPDIR/build && $out/bin/cosmocc -U__COSMOCC__ -D_COSMO_SOURCE \
          -O2 -ffunction-sections -fdata-sections \
          -c -o mmap.o $TMPDIR/cosmosrc/libc/intrin/mmap.c )
      chmod -R u+w $out
      $out/bin/x86_64-linux-cosmo-ar r \
        $out/x86_64-linux-cosmo/lib/libcosmo.a $TMPDIR/build/mmap.o
      $out/bin/aarch64-linux-cosmo-ar r \
        $out/aarch64-linux-cosmo/lib/libcosmo.a $TMPDIR/build/.aarch64/mmap.o

      runHook postUnpack
    '';

    installPhase = "true";

    meta = with lib; {
      description = "Cosmopolitan compiler toolchain (cosmocc ${version})";
      homepage = "https://cosmo.zip/";
      license = [ licenses.isc ];
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };

    passthru = {
      # apelink output OS support vector bits (from `apelink -h`):
      # 1=linux  2=metal  4=windows  8=xnu(mac)  16=openbsd  32=freebsd  64=netbsd
      apelinkPlatformBits = {
        linux = 1;
        windows = 4;
        macos = 8;
        freebsd = 32;
      };
    };
  };

  supportedArches = [ "x86_64" "aarch64" ];
  resolveArch = name:
    if builtins.elem name supportedArches then name
    else throw "cosmocc.nix: unsupported arch ${name}";
  hostArch = resolveArch pkgs.stdenv.hostPlatform.parsed.cpu.name;

  # See docs/platforms/cosmocc.md "Toolchain wiring" traps for the why behind:
  # - single-arch driver ($COSMOS env honoured)
  # - shell shims (cosmocross arch-prefix check, APE bintools ENOEXEC)
  #
  # Parameterized by `archPrefix` so cross-arch wiring (e.g. x86_64-linux
  # build host targeting aarch64-cosmo) can synthesize the right driver.
  # The native `cosmoStdenv` below always uses `hostArch`.
  mkCcUnwrapped = archPrefix: pkgs.runCommand "cosmocc-cc-${version}-${archPrefix}-unwrapped"
    {
      passthru = {
        isGNU = true;
        version = "14.1.0";
      };
      meta = (cosmocc.meta or { }) // {
        description = "cosmocc single-arch compilers re-exposed as gcc/cc/g++/c++";
      };
    } ''
    mkdir -p $out
    for d in ${cosmocc}/*; do
      ln -s "$d" "$out/$(basename "$d")"
    done
    rm $out/bin
    mkdir -p $out/bin
    for f in ${cosmocc}/bin/*; do
      ln -s "$f" "$out/bin/$(basename "$f")"
    done
    wrap() {
      cat > "$out/bin/$1" <<EOF
    #!/bin/sh
    exec "${cosmocc}/bin/$2" "\$@"
    EOF
      chmod +x "$out/bin/$1"
    }
    wrap gcc ${archPrefix}-unknown-cosmo-cc
    wrap cc  ${archPrefix}-unknown-cosmo-cc
    wrap g++ ${archPrefix}-unknown-cosmo-c++
    wrap c++ ${archPrefix}-unknown-cosmo-c++
    cat > $out/bin/cpp <<EOF
    #!/bin/sh
    exec "${cosmocc}/bin/${archPrefix}-unknown-cosmo-cc" -E "\$@"
    EOF
    chmod +x $out/bin/cpp
  '';

  mkBintoolsUnwrapped = archPrefix: pkgs.runCommand "cosmocc-bintools-${version}-${archPrefix}-unwrapped"
    {
      passthru = {
        isGNU = true;
        targetPrefix = "";
      };
    } ''
    mkdir -p $out/bin
    for tool in ar ranlib addr2line ld nm strip objcopy objdump readelf as size c++filt elfedit; do
      if [ -e ${cosmocc}/bin/${archPrefix}-linux-cosmo-$tool ]; then
        cat > $out/bin/$tool <<EOF
    #!/bin/sh
    exec "${cosmocc}/bin/${archPrefix}-linux-cosmo-$tool" "\$@"
    EOF
        chmod +x $out/bin/$tool
      fi
    done
  '';

  cosmoCCUnwrapped = mkCcUnwrapped hostArch;
  cosmoBintoolsUnwrapped = mkBintoolsUnwrapped hostArch;

  cosmoBintools = pkgs.wrapBintoolsWith {
    bintools = cosmoBintoolsUnwrapped;
    libc = null;
  };

  cosmoCC = pkgs.wrapCCWith {
    cc = cosmoCCUnwrapped;
    bintools = cosmoBintools;
    libc = null;
    extraPackages = [ ];
  };

  cosmoStdenv = pkgs.stdenvAdapters.addAttrsToDerivation
    {
      dontPatchELF = true;
      dontStrip = true;
      hardeningDisable = [ "all" ];
    }
    (pkgs.overrideCC pkgs.stdenv cosmoCC);

  # Helpers used by mkPkgsCosmo to swap the cross-stdenv's compiler/bintools
  # for the cosmocc ones, preserving the cross target prefix that the
  # nixpkgs-generated wrappers already carry.
  #
  # The cosmocc bin/ ships unprefixed tools (gcc, ar, ld, …) plus the real
  # binaries (x86_64-unknown-cosmo-cc, x86_64-linux-cosmo-ar, …). nixpkgs's
  # cc-wrapper looks for `${ccPath}/${targetPrefix}gcc` and bintools-wrapper
  # likewise — so we synthesize the target-prefixed names as symlinks back
  # to the shims we already built.
  #
  # `targetArch` defaults to the build host's arch (cross-arch within cosmo
  # is unusual: the cosmocc zip ships both x86_64 and aarch64 single-arch
  # drivers, but emitting the wrong one for the target produces broken APEs).
  mkCrossWiring =
    { buildPackages
    , baseStdenv
    , targetPrefix
    , targetArch ? hostArch
    }: rec {
    targetCcUnwrapped = mkCcUnwrapped (resolveArch targetArch);
    targetBintoolsUnwrapped = mkBintoolsUnwrapped (resolveArch targetArch);

    ccUnwrappedCross = buildPackages.runCommand "cosmocc-cc-cross-unwrapped"
      {
        inherit (targetCcUnwrapped) passthru;
      } ''
      mkdir -p $out/bin
      for d in ${targetCcUnwrapped}/*; do
        n=$(basename "$d")
        [ "$n" = bin ] && continue
        ln -sf "$d" "$out/$n"
      done
      for f in ${targetCcUnwrapped}/bin/*; do
        ln -sf "$f" "$out/bin/$(basename "$f")"
      done
      for tool in gcc g++ cpp cc c++; do
        if [ -e ${targetCcUnwrapped}/bin/$tool ]; then
          ln -sf ${targetCcUnwrapped}/bin/$tool "$out/bin/${targetPrefix}$tool"
        fi
      done
    '';

    bintoolsUnwrappedCross = buildPackages.runCommand "cosmocc-bintools-cross-unwrapped"
      {
        inherit (targetBintoolsUnwrapped) passthru;
      } ''
      mkdir -p $out/bin
      for f in ${targetBintoolsUnwrapped}/bin/*; do
        n=$(basename "$f")
        ln -sf "$f" "$out/bin/$n"
        ln -sf "$f" "$out/bin/${targetPrefix}$n"
      done
    '';

    crossBintools = baseStdenv.cc.bintools.override {
      bintools = bintoolsUnwrappedCross;
      libc = null;
    };

    crossCC = baseStdenv.cc.override {
      cc = ccUnwrappedCross;
      bintools = crossBintools;
      libc = null;
    };

    # Setup hook that teaches every autotools package's config.sub about
    # `cosmo-gnu`. Lives at build time inside the host package's source
    # tree — no `gnu-config` derivation override, so xgcc/bootstrap stay
    # cached. See ../cosmo-config-sub-hook.sh for the patch shape.
    configSubHook = buildPackages.makeSetupHook
      { name = "cosmo-config-sub-hook"; }
      ./cosmo-config-sub-hook.sh;

    stdenv =
      let
        ccOverridden = buildPackages.overrideCC baseStdenv crossCC;
        withHook = ccOverridden.override (old: {
          extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ]) ++ [ configSubHook ];
        });
        # cosmocc is static-only (no .so). makeStaticLibraries injects
        # `--disable-shared`/`--enable-static` (+ cmake/meson equivalents)
        # into every mkDerivation. Applied here means it only affects the
        # host-side cosmo stdenv — buildPackages stay glibc with default
        # shared behaviour, no bootstrap cascade.
        staticified = buildPackages.stdenvAdapters.makeStaticLibraries withHook;
      in
      buildPackages.stdenvAdapters.addAttrsToDerivation
        {
          dontPatchELF = true;
          dontStrip = true;
          hardeningDisable = [ "all" ];
        }
        staticified;
  };
in
cosmoStdenv // {
  inherit
    cosmocc
    cosmoCCUnwrapped
    cosmoBintoolsUnwrapped
    mkCrossWiring
    version
    ;
  platformBits = cosmocc.passthru.apelinkPlatformBits;
}
