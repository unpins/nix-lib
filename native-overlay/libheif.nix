# pkgsStatic.libheif: decode-only, built-in codecs, no gdk-pixbuf plugin.
#
# nixpkgs builds libheif with the full encoder set (x265, rav1e, libaom), a
# gdk-pixbuf loader module, and example tools. A static decode consumer
# (chafa links libheif.a to read HEIC/AVIF, never writes, never uses the
# tools) needs none of it — and rav1e (a Rust crate that vendors a
# multi-hundred-MB cargo tree) is both unused and a tmpfs-filler. So build
# the library only:
#   - drop the rav1e/x265/libaom encoders AND gdk-pixbuf from inputs so nix
#     never realizes them. gdk-pixbuf transitively drags libtiff, whose
#     static CMake export (TiffTargets.cmake) names a `Deflate::Deflate`
#     target that libheif's heifio find_package(TIFF) can't resolve —
#     dropping gdk-pixbuf removes libtiff from the build env and the example
#     I/O lib that needs it.
#   - ENABLE_PLUGIN_LOADING=OFF — codecs link in statically, not as dlopen
#     .so plugins (a static build can't load them)
#   - WITH_GDK_PIXBUF / WITH_EXAMPLES / BUILD_TESTING = OFF — loader .so,
#     CLI tools (+ heifio), and the test suite are all unused here
#   - WITH_LIBDE265 + WITH_DAV1D = ON — HEVC + AV1 decode (HEIC/AVIF)
#   - WITH_X265 / RAV1E / AOM_* / SvtEnc = OFF — encoders
# postInstall (the heif.thumbnailer rewrite) is replaced: with the tools off,
# the `bin`/`man`/`out` outputs would be empty and nix fails on a missing
# output path, so just create the declared dirs (the real artifacts land in
# `lib`/`dev`).
#
# pkgsStatic auto-promotes buildInputs into propagatedBuildInputs, so the
# encoders must be dropped from BOTH or the old closure (and rav1e's build)
# survives. See [[feedback_pkgsstatic_propagated_buildinputs]].
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  dropLibs = lib.filter
    (x: !(builtins.elem (x.pname or x.name or "") [ "rav1e" "x265" "libaom" "gdk-pixbuf" ]));
in
pkgs.libheif.overrideAttrs (oa: {
  buildInputs = dropLibs (oa.buildInputs or [ ]);
  propagatedBuildInputs = dropLibs (oa.propagatedBuildInputs or [ ]);
  postInstall = "mkdir -p $out $bin $man";
  doCheck = false;
  # mingw: de265.h decorates its API with __declspec(dllimport) under _WIN32
  # unless LIBDE265_STATIC_BUILD is defined, but libde265.pc doesn't carry it
  # in Cflags, so libheif.a ends up referencing __imp_de265_* thunks that the
  # static libde265.a can't satisfy at the final link. Define it for libheif's
  # own compile so it binds the plain de265_* symbols.
  NIX_CFLAGS_COMPILE = (oa.NIX_CFLAGS_COMPILE or "")
    + lib.optionalString isMinGW " -DLIBDE265_STATIC_BUILD";
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DENABLE_PLUGIN_LOADING=OFF"
    "-DWITH_LIBDE265=ON"
    "-DWITH_DAV1D=ON"
    "-DWITH_X265=OFF"
    "-DWITH_RAV1E=OFF"
    "-DWITH_AOM_ENCODER=OFF"
    "-DWITH_AOM_DECODER=OFF"
    "-DWITH_SvtEnc=OFF"
    "-DWITH_GDK_PIXBUF=OFF"
    "-DWITH_EXAMPLES=OFF"
    "-DBUILD_TESTING=OFF"
  ];
})
