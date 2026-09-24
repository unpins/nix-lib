# soxr defaults `-DWITH_OPENMP=ON`, leaving `GOMP_parallel` undef refs at
# consumer link time; `soxr.pc.in` has no `Libs.private` and ffmpeg's probe
# doesn't read it anyway, so `-lgomp` is never supplied. ffmpeg-class consumers
# parallelize higher up, so soxr-OpenMP only oversubscribes — disable it.
#
# `WITH_LSR_BINDINGS` (ON by default) installs a SECOND archive next to
# `libsoxr.a`: `libsoxr-lsr.a`, soxr's re-implementation of libsamplerate's
# `src_*` API. The mega-link sweeps every `.a` in each dep's `lib/` into one
# `--start-group`, so that shim sits in the same group as the real
# `libsamplerate.a` and can satisfy a consumer's `src_new`/`src_process` first.
# It did: ffmpeg's `-af rubberband=pitch=1.5` segfaulted because rubberband's
# resampler calls landed in soxr's emulation, which reads the caller's output
# buffer as a `float **` — and rubberband hands it a zeroed buffer, so the
# first "pointer" is NULL and soxr memcpy's into address 0. Nothing here wants
# the emulation; consumers that want libsamplerate link libsamplerate.
{ lib }:
pkgs:
pkgs.soxr.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DWITH_OPENMP=OFF"
    "-DWITH_LSR_BINDINGS=OFF"
  ];
})
