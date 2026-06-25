# Cosmopolitan toolchain wiring. Exposes:
#   - cosmocc                : raw $out from cosmocc.zip
#   - cosmoStdenv            : native stdenv with cc-wrapper around cosmocc
#   - cosmoCCUnwrapped       : single-arch cc dir w/ shims (gcc/cc/g++/c++/cpp)
#   - cosmoBintoolsUnwrapped : APE bintools shimmed for kernel exec
#   - platformBits           : apelink -V <bits> per OS
#   - mkCrossWiring          : helpers for pkgsCross.cosmo (cross-stdenv injection)
#
# `pkgs` is the build-side nixpkgs (linux-gnu).
{ pkgs }:

let
  inherit (pkgs) lib;

  version = "4.0.2";

  # Upstream mmap.c, fetched separately so we can patch it without bundling
  # cosmo source. Patch fixes the wine hang where cosmo's pickaddr loops
  # forever on STATUS_CONFLICTING_ADDRESSES; see cosmocc-wine-fix/.
  cosmoMmapSrc = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/jart/cosmopolitan/${version}/libc/intrin/mmap.c";
    hash = "sha256-xHsnD5UZCwpmPOtgWklpbXzDCFY2aVaY0YUkpTpb54k=";
  };

  # Upstream third_party/tz sources. localtime.c gets the Windows
  # system-timezone fix (see cosmocc-tz-fix/); the headers are its quoted
  # includes, which cosmocc.zip doesn't ship.
  cosmoTzSrcs = builtins.mapAttrs
    (name: hash: pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/jart/cosmopolitan/${version}/third_party/tz/${name}";
      inherit hash;
    })
    {
      "localtime.c" = "sha256-lhDnhwhOdXu59BtzelkXllzC1Zng6siYpUUBf0dx9+k=";
      "lock.h" = "sha256-ZHyA5uTlWh3UVz8sp2m03ldNMShajporm0N1cyCnZHo=";
      "tzdir.h" = "sha256-8HhA+3dQNQ5Q+keJC6NoyvsJ143BsqZUbVf5Cv0DezM=";
      "tzfile.h" = "sha256-bnnpA+HGbij354n8+mdQn+hLFY3uf7N9ZqVDG1sF6Cw=";
      "private.h" = "sha256-wxo0bQWnO/yOfoU85XVlZUNmJZvPDGrDZmeTWIqRS50=";
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

      # Same surgery on localtime.o: upstream's Windows timezone detection
      # matches the LOCALIZED zone name (never matches on non-English
      # Windows) and its numeric fallback writes a garbage byte mid-string
      # (skips buf[3]) — both silently degrade localtime() to UTC. The patch
      # matches the invariant TimeZoneKeyName instead and renumbers the
      # fallback slots; see cosmocc-tz-fix/ for the root-cause writeup.
      mkdir -p $TMPDIR/cosmosrc/third_party/tz $TMPDIR/tzbuild/.aarch64
      ${lib.concatStrings (lib.mapAttrsToList (name: src: ''
        cp ${src} $TMPDIR/cosmosrc/third_party/tz/${name}
      '') cosmoTzSrcs)}
      chmod -R u+w $TMPDIR/cosmosrc/third_party/tz
      patch -p1 -d $TMPDIR/cosmosrc < ${./cosmocc-tz-fix/tz-windows-fix.patch}
      ( cd $TMPDIR/tzbuild && $out/bin/cosmocc -U__COSMOCC__ -D_COSMO_SOURCE \
          -O2 -ffunction-sections -fdata-sections \
          -c -o localtime.o $TMPDIR/cosmosrc/third_party/tz/localtime.c )
      $out/bin/x86_64-linux-cosmo-ar r \
        $out/x86_64-linux-cosmo/lib/libcosmo.a $TMPDIR/tzbuild/localtime.o
      $out/bin/aarch64-linux-cosmo-ar r \
        $out/aarch64-linux-cosmo/lib/libcosmo.a $TMPDIR/tzbuild/.aarch64/localtime.o

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

  # See docs/platforms/cosmocc.md "Toolchain wiring" traps for the why behind
  # the single-arch driver and shell shims. Parameterized by `archPrefix` so
  # cross-arch wiring can synthesize the right driver; native `cosmoStdenv`
  # uses `hostArch`.
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
    # Short-circuit a bare --version anywhere in the argv to the real tool.
    # meson's compiler probe runs e.g. \`cc <flags> --version\`; cosmocc's cc
    # only honours --version as the FIRST arg, otherwise it tries to compile and
    # errors "no input files". Real gcc accepts it positionally, so match that.
    for a in "\$@"; do
      [ "\$a" = --version ] && exec "${cosmocc}/bin/$2" --version
    done
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
    # cosmocc's "cc -E" does not default to stdin when no input file is given
    # (real gcc/cpp does) -- it errors "no input files". autoconf/meson cpp
    # probes pipe source on stdin with no file arg; detect that no-file case and
    # append "-" so the preprocessor reads stdin.
    has_input=
    for a in "\$@"; do
      case "\$a" in
        -) has_input=1 ;;
        -*) ;;
        *) [ -f "\$a" ] && has_input=1 ;;
      esac
    done
    if [ -n "\$has_input" ]; then
      exec "${cosmocc}/bin/${archPrefix}-unknown-cosmo-cc" -E "\$@"
    fi
    exec "${cosmocc}/bin/${archPrefix}-unknown-cosmo-cc" -E "\$@" -
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

  # Helpers used by config.replaceCrossStdenv to swap the cross-stdenv's
  # compiler/bintools for the cosmocc ones, preserving the cross target prefix.
  # cosmocc bin/ ships unprefixed tools, but the wrappers look for
  # `${ccPath}/${targetPrefix}gcc` — so synthesize target-prefixed symlinks
  # back to the shims. `targetArch` defaults to the build host's arch (emitting
  # the wrong single-arch driver for the target produces broken APEs).
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

    # Teaches every autotools package's config.sub about `cosmo-gnu` at build
    # time, inside the host package's source tree — no `gnu-config` override,
    # so xgcc/bootstrap stay cached. See ../cosmo-config-sub-hook.sh.
    configSubHook = buildPackages.makeSetupHook
      { name = "cosmo-config-sub-hook"; }
      ./cosmo-config-sub-hook.sh;

    # Auto-apelinks every cosmocc-emitted ELF in $out/bin to PE32+
    # `<name>.exe`. Runs in preFixupHooks so consumer postFixup +
    # lib.withAliases operate on the final `.exe`. Fail-loud on stripped
    # binaries (apelink needs .symtab). See ../cosmo-apelink-hook.sh.
    apelinkHook = buildPackages.makeSetupHook
      {
        name = "cosmo-apelink-hook";
        substitutions = {
          apelink = "${cosmocc}/bin/apelink";
          vbits = toString cosmocc.passthru.apelinkPlatformBits.windows;
        };
      }
      ./cosmo-apelink-hook.sh;

    stdenv =
      let
        ccOverridden = buildPackages.overrideCC baseStdenv crossCC;
        withHook = ccOverridden.override (old: {
          extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ])
            ++ [ configSubHook apelinkHook ];
        });
        # cosmocc is static-only (no .so). Applying makeStaticLibraries here
        # (not lower) keeps it on the host-side cosmo stdenv only —
        # buildPackages stay glibc, no bootstrap cascade.
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
