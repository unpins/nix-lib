# libvmaf cross-mingw, two fixes:
#
# 1. `+ windows.pthreads`. `feature_collector.h` includes `<pthread.h>`
#    unconditionally; mingw's libc doesn't ship it.
#
# 2. `-Denable_tests=false`. Test executables link via probes that
#    aren't winpthreads-aware, and no downstream needs them.
{ lib }:
self: super:
super.libvmaf.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ self.windows.pthreads ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Denable_tests=false"
  ];
})
