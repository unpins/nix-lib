# fftw cross-mingw, three fixes:
#
# 1. Drop `--enable-openmp` — nixpkgs' mingw cross-gcc has no libgomp,
#    so configure aborts; `--enable-threads` (pthread) covers consumers.
#
# 2. `+ --with-our-malloc` — mingw exposes only `_aligned_malloc` (not
#    probed), so `kalloc.c` errors out; this flag uses fftw's bundled
#    aligned-malloc.
#
# 3. `+ windows.pthreads` — fftw's `AX_PTHREAD` probe needs `-lpthread`,
#    absent from the mingw cross; winpthreads provides it.
{ lib }:
self: super:
super.fftw.overrideAttrs (oa: {
  configureFlags =
    (builtins.filter (f: f != "--enable-openmp") oa.configureFlags)
    ++ [ "--with-our-malloc" ];
  buildInputs = (oa.buildInputs or [ ]) ++ [ self.windows.pthreads ];
})
