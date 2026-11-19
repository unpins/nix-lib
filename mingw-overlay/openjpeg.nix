# openjpeg on mingw: `BUILD_CODEC=ON` builds the CLI tools, which link
# libtiff. The mingw dep closure lacks libjpeg.pc (libtiff-4.pc requires it),
# so `pkg_check_modules(PC_TIFF)` fails, TIFF_LIBNAME stays empty and the tools
# don't link. Downstream (ffmpeg) only consumes the `.a`, so disable them.
{ lib }:
self: super:
super.openjpeg.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DBUILD_CODEC=OFF"
  ];
})
