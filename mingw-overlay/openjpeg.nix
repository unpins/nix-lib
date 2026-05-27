# openjpeg on mingw: cmake's `BUILD_CODEC=ON` builds the CLI tools
# (opj_compress.exe, opj_decompress.exe, opj_dump.exe), which link
# against libtiff and libpng. Under mingwStaticCross the consumer
# link probes don't resolve libtiff/libpng's transitive zlib chain
# and the tools fail with undefined `_TIFFfree` / `TIFFClose` / …
# Downstream (ffmpeg's `--enable-libopenjpeg`) only consumes the
# `.a`, so disable the codec tools.
{ lib }:
self: super:
super.openjpeg.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DBUILD_CODEC=OFF"
  ];
})
