# fftw cross-mingw, three fixes:
#
# 1. Drop `--enable-openmp` from configureFlags. nixpkgs' mingw-w64
#    cross-gcc is built without libgomp (no Win32 OMP runtime in
#    nixpkgs), and configure aborts with "don't know how to enable
#    OpenMP". `--enable-threads` (pthread) still covers consumer
#    needs (rubberband).
#
# 2. `+ --with-our-malloc`. mingw doesn't expose
#    `posix_memalign` / `memalign` / `aligned_alloc` (only
#    `_aligned_malloc`, which fftw's configure doesn't probe).
#    `kalloc.c` aborts with `#error "Don't know how to malloc()
#    aligned memory ... try configuring --with-our-malloc"`. The
#    flag activates fftw's bundled SIMD-correct aligned-malloc
#    (~0 KB to the static lib).
#
# 3. `+ windows.pthreads` in buildInputs. fftw's `AX_PTHREAD`
#    autoconf probe tries `-lpthread`; the mingw cross has no
#    system pthreads. winpthreads provides it.
{ lib }:
self: super:
super.fftw.overrideAttrs (oa: {
  configureFlags =
    (builtins.filter (f: f != "--enable-openmp") oa.configureFlags)
    ++ [ "--with-our-malloc" ];
  buildInputs = (oa.buildInputs or [ ]) ++ [ self.windows.pthreads ];
})
