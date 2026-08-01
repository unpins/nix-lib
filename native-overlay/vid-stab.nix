# Darwin-only fix. vid.stab propagates `llvmPackages.openmp`, which pulls
# `pkgsStatic.python3` (broken on darwin; see [[fftw]]). The fixed
# variant would instead trigger building `llvm-static-darwin` (also broken
# upstream), so drop openmp entirely; `find_package(OpenMP)` returns false and
# the lib falls back to sequential transforms (latency-bound, negligible).
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then
  pkgs.vid-stab.overrideAttrs
    (_: {
      propagatedBuildInputs = [ ];
      buildInputs = [ ];
    })
else pkgs.vid-stab
