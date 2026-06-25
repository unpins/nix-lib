# nixpkgs `pkgsStatic.quirc`: the `all` target builds `libquirc.so` which
# fails the static link (`R_X86_64_32 against __TMC_END__`), and upstream
# postInstall `rm`s `libquirc.a` (fatal for static). The Makefile also emits
# no `quirc.pc`. So build `libquirc.a` directly, install lib + header by hand,
# and generate a minimal `.pc`. `libjpeg`/`libpng` are only for the `qrtest`
# CLI — safe to leave in buildInputs (the lib doesn't link them).
#
# `SDL_CFLAGS=`/`SDL_LIBS=` empty: the Makefile's `$(shell pkg-config --cflags
# sdl)` otherwise captures STDERR into CFLAGS when `sdl.pc` is absent.
{ lib }:
pkgs:
pkgs.quirc.overrideAttrs (_oa: {
  buildPhase = ''
    runHook preBuild
    make libquirc.a SDL_CFLAGS= SDL_LIBS=
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 libquirc.a $out/lib/libquirc.a
    install -Dm644 lib/quirc.h $out/include/quirc.h
    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/quirc.pc <<EOF
    prefix=$out
    exec_prefix=$out
    libdir=$out/lib
    includedir=$out/include

    Name: quirc
    Description: QR code recognition library
    Version: 1.2
    Libs: -L\''${libdir} -lquirc
    Libs.private: -lm
    Cflags: -I\''${includedir}
    EOF
    runHook postInstall
  '';
  postInstall = "";
  preInstall = "";
})
