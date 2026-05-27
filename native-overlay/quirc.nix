# nixpkgs `pkgsStatic.quirc`: Makefile's `all` target builds
# `libquirc.so + qrtest` by default. In pkgsStatic the `.so` fails to
# link with `R_X86_64_32 against __TMC_END__` (same family as
# xvidcore / libcaca). Upstream's postInstall does `rm $out/lib/
# libquirc.a` (correct for the dynamic default, fatal for static).
# Plus, the Makefile doesn't generate `quirc.pc` — consumers calling
# `pkg-config quirc` would fail.
#
# Fix: build `libquirc.a` directly, install it + header by hand, and
# generate a minimal `.pc` ourselves. `libjpeg`/`libpng` in upstream
# buildInputs are for the `qrtest` CLI; the library proper doesn't
# link against them, so leaving them in is safe (no link-time
# reference from `libquirc.a`).
#
# The Makefile top runs `$(shell pkg-config --cflags sdl)` — without
# `sdl.pc` available it captures STDERR and injects that text into
# CFLAGS. Pass `SDL_CFLAGS=` / `SDL_LIBS=` empty to neutralize the
# probe.
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
