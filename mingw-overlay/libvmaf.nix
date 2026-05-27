# libvmaf on mingw, two issues stack:
#
# 1. `src/feature/feature_collector.h` includes `<pthread.h>`
#    unconditionally, but mingw's libc doesn't ship it (lives in
#    `windows.pthreads`). Add winpthreads to buildInputs so the
#    header resolves.
#
# 2. With the lib building, libvmaf's meson tries to link the test
#    binaries (`test_feature_extractor.exe`, …) which need pthread
#    functions resolved at link time. The test executables aren't
#    in any consumer's closure; disable them via `-Dbuilt_in_models`
#    and `-Denable_tests=false`.
{ lib }:
self: super:
super.libvmaf.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ self.windows.pthreads ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Denable_tests=false"
  ];
})
