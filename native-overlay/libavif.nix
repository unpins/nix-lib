# pkgsStatic.libavif: static-only, drop the gdk-pixbuf loader + apps/tests.
#
# The shared link fails under pkgsStatic (crtbeginT.o R_X86_64_32 against
# hidden `__TMC_END__`), so BUILD_SHARED_LIBS=OFF and the gdk-pixbuf loader /
# apps / tests are unused by transitive lib consumers (chafa, ImageMagick).
# dav1d + libaom codecs stay SYSTEM.
#
# postFixup is guarded: static-only drops the CMake package config (it rides
# on the shared target), so the upstream _IMPORT_PREFIX rewrite would hit a
# missing libavif-config.cmake and abort.
#
# mingw: drop gdk-pixbuf + make-shell-wrapper-hook — the wrapper hook splices
# to a mingw bash that can't cross-compile (no sigset_t/fork). Gated to mingw
# to keep native/darwin's cached closure.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  dropNative = lib.filter
    (x: !(builtins.elem (x.pname or x.name or "") [ "gdk-pixbuf" "make-shell-wrapper-hook" ]));
in
pkgs.libavif.overrideAttrs (oa: {
  nativeBuildInputs =
    if isMinGW then dropNative (oa.nativeBuildInputs or [ ]) else (oa.nativeBuildInputs or [ ]);
  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=OFF"
    "-DAVIF_CODEC_AOM=SYSTEM"
    "-DAVIF_CODEC_DAV1D=SYSTEM"
    "-DAVIF_BUILD_APPS=OFF"
    "-DAVIF_BUILD_GDK_PIXBUF=OFF"
    "-DAVIF_LIBSHARPYUV=SYSTEM"
    "-DAVIF_LIBXML2=SYSTEM"
    "-DAVIF_BUILD_TESTS=OFF"
  ];
  doCheck = false;
  postInstall = "";
  postFixup = ''
    cfg="$dev/lib/cmake/libavif/libavif-config.cmake"
    if [ -f "$cfg" ]; then
      substituteInPlace "$cfg" \
        --replace-quiet "_IMPORT_PREFIX \"$out\"" "_IMPORT_PREFIX \"$dev\""
    fi
  '';
})
