# soxr on mingw: library only.
#
# `tests/throughput.c` opens with `#define k 1000` and then includes
# <windows.h>. mingw-w64's winnt.h pulls <x86intrin.h> for clang, which reaches
# amxintrin.h — whose `_tile_dpbssd_internal` takes a parameter named `k`. The
# macro expands inside the header and the file cannot parse. gcc never got here
# because its winnt.h path does not include the AMX intrinsics.
#
# Upstream defaults BUILD_TESTS ON and nixpkgs leaves it; nothing runs them
# (no checkPhase), and we consume soxr as a library through ffmpeg. Filtering
# first keeps a future nixpkgs `-DBUILD_TESTS=ON` from sitting next to our OFF.
{ lib }:
self: super:
super.soxr.overrideAttrs (oa: {
  cmakeFlags =
    builtins.filter
      (f: !(lib.hasPrefix "-DBUILD_TESTS=" (toString f)))
      (oa.cmakeFlags or [ ])
    ++ [ "-DBUILD_TESTS=OFF" ];
})
