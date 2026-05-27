# Darwin-only fix. Linux vid-stab caches cleanly (no churn).
#
# vid.stab on darwin clang propagates `llvmPackages.openmp` for
# parallel stabilization. The openmp package has Python OMPD/GDB
# scripts mis-classified as `buildInputs` → pulls
# `pkgsStatic.python3` (broken on darwin). Replacing openmp with
# the fixed variant (see [[llvm-openmp]]) avoids the python issue
# but in turn triggers building `llvm-static-darwin`, which is
# also broken upstream (`libatomic` probe fails). Until LLVM
# static-darwin builds, drop openmp from the propagation entirely.
# CMake's `find_package(OpenMP)` returns false at vid.stab
# configure; the library falls back to sequential transforms.
# Single-clip stabilization is latency-bound (not throughput-bound),
# so the runtime impact is negligible.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then
  pkgs.vid-stab.overrideAttrs (_oa: {
    propagatedBuildInputs = [ ];
    buildInputs = [ ];
  })
else pkgs.vid-stab
