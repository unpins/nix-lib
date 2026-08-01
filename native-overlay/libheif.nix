# pkgsStatic.libheif: decode-only, built-in codecs, no gdk-pixbuf plugin.
# The static decode consumer (chafa reads HEIC/AVIF, never encodes) needs no
# encoders or tools, and rav1e vendors a multi-hundred-MB cargo tree.
#
#   - drop rav1e/x265/libaom + gdk-pixbuf from inputs. gdk-pixbuf drags
#     libtiff, whose static CMake export names a `Deflate::Deflate` target
#     that libheif's heifio find_package(TIFF) can't resolve.
#   - ENABLE_PLUGIN_LOADING=OFF — codecs link in statically (a static build
#     can't dlopen .so plugins).
#   - WITH_GDK_PIXBUF / WITH_EXAMPLES / BUILD_TESTING = OFF; WITH_LIBDE265 +
#     WITH_DAV1D = ON (HEVC + AV1 decode); encoders OFF.
# postInstall just mkdirs the declared bin/man/out outputs — with tools off
# they'd be empty and nix fails on a missing output path.
#
# pkgsStatic auto-promotes buildInputs → propagated, so the encoders must be
# dropped from BOTH. See [[feedback_pkgsstatic_propagated_buildinputs]].
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  dropLibs = builtins.filter
    (x: !(builtins.elem (x.pname or x.name or "") [ "rav1e" "x265" "libaom" "gdk-pixbuf" ]));
in
pkgs.libheif.overrideAttrs (oa: {
  buildInputs = dropLibs (oa.buildInputs or [ ]);
  propagatedBuildInputs = dropLibs (oa.propagatedBuildInputs or [ ]);
  postInstall = "mkdir -p $out $bin $man";
  doCheck = false;
  # mingw: de265.h decorates its API __declspec(dllimport) under _WIN32 unless
  # LIBDE265_STATIC_BUILD is defined, which libde265.pc omits from Cflags — so
  # libheif.a references __imp_de265_* thunks static libde265.a can't satisfy.
  # Define it for libheif's compile so it binds the plain de265_* symbols.
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
