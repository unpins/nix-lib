# openjpeg on mingw: `BUILD_CODEC=ON` builds CLI tools linking libtiff
# and libpng, whose transitive zlib chain the static cross-mingw probes
# can't resolve (undefined `_TIFFfree`/`TIFFClose`/…). Downstream
# (ffmpeg) only consumes the `.a`, so disable the codec tools.
{ lib }:
self: super:
super.openjpeg.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DBUILD_CODEC=OFF"
  ];
})
