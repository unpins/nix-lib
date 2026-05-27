# libvmaf cross-mingw, two fixes:
#
# 1. `+ windows.pthreads`. `src/feature/feature_collector.h`
#    includes `<pthread.h>` unconditionally; mingw's libc doesn't
#    ship it.
#
# 2. `-Denable_tests=false`. The test executables
#    (`test_feature_extractor.exe`, …) are linked from the same
#    meson run; without disabling them the build invokes the
#    consumer link probes that aren't winpthreads-aware. No
#    downstream needs them.
{ lib }:
self: super:
super.libvmaf.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ self.windows.pthreads ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Denable_tests=false"
  ];
})
