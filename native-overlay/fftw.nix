# fftw drops `--enable-openmp` on darwin and mingw.
#
# Linux fftw caches cleanly (no churn) — `else pkgs.fftw`.
#
# Two upstream problems stack on pkgsStatic-darwin:
#
# 1. nixpkgs propagates `llvmPackages.openmp` as a `buildInput` on
#    clang stdenvs (via `--enable-openmp` configure default). The
#    openmp package mis-classifies its OMPD/GDB Python helpers as
#    `buildInputs` instead of `nativeBuildInputs`, so consumers
#    propagate `pkgsStatic.python3` (`meta.broken = true` on darwin).
#    See [[llvm-openmp]] for the bug & the would-be structural fix
#    via `ompdGdbSupport = false`. **However**, using that fixed
#    openmp triggers a build of `llvmPackages.openmp` itself, which
#    pulls `llvm-static-x86_64-apple-darwin` — and *that* build is
#    broken upstream too (`Host compiler appears to require
#    libatomic, but cannot find it`). Until LLVM static darwin
#    builds clean, side-step openmp entirely: swap the dep for an
#    `emptyDirectory` placeholder and drop `--enable-openmp` from
#    configure. fftw still builds with `--enable-threads` (pthread
#    parallelism), which is what real consumers
#    (e.g. rubberband's `fftw_plan_*`) actually exercise.
#
# 2. `gfortran-wrapper` lands in `nativeBuildInputs` but fftw never
#    sets `--enable-fortran`, so the C-only build path never invokes
#    it. On pkgsStatic-darwin, building the cross-gfortran-wrapper
#    pulls a full GCC cross with `objc,obj-c++` languages enabled,
#    and that GCC build fails (missing isl 0.15+, missing darwin
#    objc bridge). Drop the unused wrapper.
#
# On cross-mingw the same `--enable-openmp` flag aborts configure
# with "don't know how to enable OpenMP" — gfortran-wrapper-mingw
# probes for `-fopenmp` but cross-gcc-mingw is built without libgomp
# (no OMP runtime for win32 in nixpkgs' mingw-w64 stdenv). Drop the
# flag; threads still cover rubberband's needs. `llvmPackages.openmp`
# isn't on the gcc-mingw cross path, so no buildInputs swap needed.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isMinGW  = pkgs.stdenv.hostPlatform.isMinGW or false;
in
if isDarwin
then
  (pkgs.fftw.override {
    llvmPackages = { openmp = pkgs.emptyDirectory; };
  }).overrideAttrs (oa: {
    buildInputs = [ ];
    nativeBuildInputs = builtins.filter
      (d: !(d.pname or null == "gfortran-wrapper"))
      (oa.nativeBuildInputs or [ ]);
    configureFlags =
      builtins.filter (f: f != "--enable-openmp") oa.configureFlags;
  })
else if isMinGW
then
  pkgs.fftw.overrideAttrs (oa: {
    configureFlags =
      (builtins.filter (f: f != "--enable-openmp") oa.configureFlags)
      # mingw doesn't expose `posix_memalign`/`memalign`/`aligned_alloc`
      # (only `_aligned_malloc`, which fftw's configure doesn't probe).
      # `kalloc.c` aborts with `#error "Don't know how to malloc()
      # aligned memory ... try configuring --with-our-malloc"`.
      # `--with-our-malloc` activates fftw's own bundled aligned-malloc
      # (`kernel/kalloc.c` MALLOC fast-path), which is SIMD-correct and
      # adds ~0 KB to the static lib.
      ++ [ "--with-our-malloc" ];
    # `--enable-threads` is still in configureFlags. fftw's
    # AX_PTHREAD probe tries `-lpthread` etc but the mingw cross
    # has no system pthreads — `pkgs.windows.pthreads` (winpthreads)
    # provides it. Add it to buildInputs so `-lpthread` resolves.
    buildInputs = (oa.buildInputs or [ ]) ++ [ pkgs.windows.pthreads ];
  })
else pkgs.fftw
