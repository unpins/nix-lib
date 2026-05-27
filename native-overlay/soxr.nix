# soxr defaults `-DWITH_OPENMP=ON` (parallel resampling), pulling
# `libgomp` undefined refs (`GOMP_parallel`) at consumer link time.
# Upstream's `soxr.pc.in` declares no `Libs.private`, and many
# consumers' link probes are `require` rather than
# `require_pkg_config` (e.g. ffmpeg's libsoxr probe), so `.pc` is
# unread anyway — the consumer would need `--extra-libs=-lgomp` to
# link.
#
# Most ffmpeg-class consumers already parallelize at a higher level
# (filtergraph thread pool, etc); soxr-OpenMP just creates
# thread-on-thread oversubscription on top. Disable openmp and let
# the consumer manage the thread pool. If a future consumer needs
# in-soxr parallelism, write a sibling fix that keeps openmp on.
{ lib }:
pkgs:
pkgs.soxr.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_OPENMP=OFF" ];
})
