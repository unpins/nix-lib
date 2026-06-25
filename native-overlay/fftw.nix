# pkgsStatic.fftw — two upstream issues. (1) all-platform; (2) darwin-only
# (mingw is in mingw-overlay/fftw.nix).
#
# 1. `gfortran-wrapper` is in nativeBuildInputs on every platform, but fftw
#    never sets `--enable-fortran`, so it's a realized-but-unused input forcing
#    a full cross-GCC build — fails on pkgsStatic-darwin (missing isl 0.15+),
#    wasteful elsewhere. Strip it: output-neutral (only the hash moves), drops
#    cross-gfortran from every consumer's graph (rubberband → ffmpeg).
#
# 2. nixpkgs propagates `llvmPackages.openmp` (clang `--enable-openmp` default),
#    which mis-classifies its OMPD/GDB helpers as buildInputs → pulls
#    pkgsStatic.python3 (broken on darwin). The structural fix ([[llvm-openmp]],
#    `ompdGdbSupport = false`) would build openmp itself, pulling a broken
#    llvm-static. Side-step with `emptyDirectory`; fftw keeps `--enable-threads`
#    (pthread), which is what consumers exercise.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  stripGfortran = oa: builtins.filter
    (d: !(d.pname or null == "gfortran-wrapper"))
    (oa.nativeBuildInputs or [ ]);
in
if isDarwin
# `.override` before `.overrideAttrs` — re-invoking the function discards a
# prior overrideAttrs.
then
  (pkgs.fftw.override {
    llvmPackages = { openmp = pkgs.emptyDirectory; };
  }).overrideAttrs (oa: {
    buildInputs = [ ];
    nativeBuildInputs = stripGfortran oa;
    configureFlags =
      builtins.filter (f: f != "--enable-openmp") oa.configureFlags;
  })
else pkgs.fftw.overrideAttrs (oa: { nativeBuildInputs = stripGfortran oa; })
