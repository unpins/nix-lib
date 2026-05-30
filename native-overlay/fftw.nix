# pkgsStatic.fftw — two upstream issues. (1) is all-platform; (2) is
# darwin-only (mingw is handled by mingw-overlay/fftw.nix).
#
# 1. `gfortran-wrapper` lands in `nativeBuildInputs` on EVERY platform
#    but fftw never sets `--enable-fortran`, so the C-only build never
#    invokes it. The wrapper is still a realized input, which forces a
#    full cross-GCC build. On pkgsStatic-darwin that cross-gfortran
#    FAILS (missing isl 0.15+, objc/obj-c++ bridge) — a hard blocker.
#    On pkgsStatic-linux/musl it merely builds a whole GCC from source
#    for nothing (~30-60 min, not on cache.nixos.org). Strip the unused
#    wrapper on all platforms: output-neutral (the `.a` is byte-identical,
#    only the hash moves) and removes cross-gfortran from every fftw
#    consumer's graph (rubberband -> ffmpeg).
#
# 2. nixpkgs propagates `llvmPackages.openmp` as a buildInput on
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
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # (1) — applies everywhere.
  stripGfortran = oa: builtins.filter
    (d: !(d.pname or null == "gfortran-wrapper"))
    (oa.nativeBuildInputs or [ ]);
in
if isDarwin
# `.override` (openmp) BEFORE `.overrideAttrs` — re-invoking the function
# would discard a prior overrideAttrs.
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
