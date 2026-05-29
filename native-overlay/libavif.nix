# pkgsStatic.libavif: static-only, drop the gdk-pixbuf loader + apps/tests.
#
# nixpkgs builds libavif with BUILD_SHARED_LIBS=ON plus a gdk-pixbuf loader
# module (contrib/gdk-pixbuf/libpixbufloader-avif.so). Under pkgsStatic the
# shared link dies the usual way:
#   crtbeginT.o: relocation R_X86_64_32 against hidden symbol `__TMC_END__'
#   can not be used when making a shared object
# Consumers (chafa, ImageMagick) link the static avif lib, so:
#   - BUILD_SHARED_LIBS=OFF      — no .so at all
#   - AVIF_BUILD_GDK_PIXBUF=OFF  — that loader is the failing .so, and its
#     runtime hookup (gdk-pixbuf-query-loaders + thumbnailer wrapper in
#     postInstall) is meaningless for a static lib
#   - AVIF_BUILD_APPS/TESTS=OFF  — avifenc/avifdec + gtest are unused by a
#     transitive lib consumer
# postInstall is emptied (it only did the loader cache + thumb wrapper) and
# doCheck turned off. dav1d (decode) + libaom (encode) codecs stay SYSTEM.
#
# Static-only also drops libavif's CMake package config — the install(EXPORT)
# rides on the shared target — so nixpkgs' postFixup (which rewrites
# _IMPORT_PREFIX in libavif-config.cmake) hits a missing file and aborts.
# Guard it: consumers here resolve libavif via pkg-config (libavif.pc, still
# emitted), and the rewrite stays correct for any build where the config
# does exist.
# mingw addendum: vanilla libavif lists gdk-pixbuf + make-shell-wrapper-hook
# in nativeBuildInputs (to run gdk-pixbuf-query-loaders for the loader module
# we disable above). Harmless on native (an unused build tool), but the
# wrapper hook is spliced to a *mingw* bash, and bash can't cross-compile to
# win32 (no sigset_t/fork) → `unknown type name 'sigset_t'`. With the loader,
# apps and postInstall all off nothing needs either, so drop them — gated to
# mingw so native/darwin libavif keeps its cached closure.
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
