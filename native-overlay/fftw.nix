# pkgsStatic.fftw — drop `--enable-openmp` on darwin (mingw is
# handled by mingw-overlay/fftw.nix); linux passes through.
#
# Two stacked upstream problems on pkgsStatic-darwin:
#
# 1. nixpkgs propagates `llvmPackages.openmp` as a buildInput on
#    clang stdenvs (via `--enable-openmp` configure default). That
#    openmp mis-classifies its OMPD/GDB Python helpers as
#    `buildInputs` instead of `nativeBuildInputs`, propagating
#    `pkgsStatic.python3` (`meta.broken` on darwin). See
#    [[llvm-openmp]] for the structural fix
#    (`ompdGdbSupport = false`) — but using a fixed openmp triggers
#    a build of `llvmPackages.openmp` itself, which pulls
#    `llvm-static-x86_64-apple-darwin` (also broken: missing
#    libatomic). Side-step openmp entirely: swap the dep for
#    `emptyDirectory`. fftw still uses `--enable-threads` (pthread
#    parallelism), which is what consumers (rubberband) exercise.
#
# 2. `gfortran-wrapper` lands in `nativeBuildInputs` but fftw
#    never sets `--enable-fortran`, so the C-only build never
#    invokes it. On pkgsStatic-darwin, building cross-gfortran-
#    wrapper pulls a full GCC cross with `objc,obj-c++` enabled,
#    which fails (missing isl 0.15+, darwin objc bridge). Drop
#    the unused wrapper.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
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
else pkgs.fftw
