# soxr defaults `-DWITH_OPENMP=ON`, leaving `GOMP_parallel` undef refs at
# consumer link time; `soxr.pc.in` has no `Libs.private` and ffmpeg's probe
# doesn't read it anyway, so `-lgomp` is never supplied. ffmpeg-class consumers
# parallelize higher up, so soxr-OpenMP only oversubscribes — disable it.
{ lib }:
pkgs:
pkgs.soxr.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_OPENMP=OFF" ];
})
