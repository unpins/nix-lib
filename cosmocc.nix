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

  arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  archPrefix =
    if arch == "x86_64" then "x86_64"
    else if arch == "aarch64" then "aarch64"
    else throw "cosmocc.nix: unsupported arch ${arch}";

  # See docs/platforms/cosmocc.md "Toolchain wiring" traps for the why behind:
  # - single-arch driver ($COSMOS env honoured)
  # - shell shims (cosmocross arch-prefix check, APE bintools ENOEXEC)
  cosmoCCUnwrapped = pkgs.runCommand "cosmocc-cc-${version}-unwrapped"
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

  cosmoBintoolsUnwrapped = pkgs.runCommand "cosmocc-bintools-${version}-unwrapped"
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
  mkCrossWiring = { buildPackages, baseStdenv, targetPrefix }: rec {
    ccUnwrappedCross = buildPackages.runCommand "cosmocc-cc-cross-unwrapped"
      {
        inherit (cosmoCCUnwrapped) passthru;
      } ''
      mkdir -p $out/bin
      for d in ${cosmoCCUnwrapped}/*; do
        n=$(basename "$d")
        [ "$n" = bin ] && continue
        ln -sf "$d" "$out/$n"
      done
      for f in ${cosmoCCUnwrapped}/bin/*; do
        ln -sf "$f" "$out/bin/$(basename "$f")"
      done
      for tool in gcc g++ cpp cc c++; do
        if [ -e ${cosmoCCUnwrapped}/bin/$tool ]; then
          ln -sf ${cosmoCCUnwrapped}/bin/$tool "$out/bin/${targetPrefix}$tool"
        fi
      done
    '';

    bintoolsUnwrappedCross = buildPackages.runCommand "cosmocc-bintools-cross-unwrapped"
      {
        inherit (cosmoBintoolsUnwrapped) passthru;
      } ''
      mkdir -p $out/bin
      for f in ${cosmoBintoolsUnwrapped}/bin/*; do
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

    stdenv =
      buildPackages.stdenvAdapters.addAttrsToDerivation
        {
          dontPatchELF = true;
          dontStrip = true;
          hardeningDisable = [ "all" ];
        }
        (buildPackages.overrideCC baseStdenv crossCC);
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
