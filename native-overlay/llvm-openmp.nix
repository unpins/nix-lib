# nixpkgs `llvmPackages.openmp`: `ompdGdbSupport` (default true) mis-classifies
# `python3` as a `buildInputs` (host) dep to install OMPD/GDB debug scripts that
# only `gdb` loads at debug time. Two consequences:
#
# 1. Consumers linking `libomp.a` propagate `pkgsStatic.python3` into their
#    closure — ~50 MB + a long Python build for code that never runs.
#
# 2. On pkgsStatic-darwin `python3-3.13.x` is `meta.broken` (CPython won't link
#    fully-static on macOS), so eval of any openmp consumer (fftw, vid-stab,
#    rubberband) crashes.
#
# `ompdGdbSupport = false` drops `python3` from `buildInputs` (still in
# `nativeBuildInputs` for configure-time Python — the legitimate use).
# Upstream-fixable: it should be a `nativeBuildInputs` dep.
{ lib }:
pkgs:
pkgs.llvmPackages.openmp.override { ompdGdbSupport = false; }
