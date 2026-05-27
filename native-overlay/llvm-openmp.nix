# nixpkgs's `llvmPackages.openmp` (LLVM's `libomp`) takes a knob
# `ompdGdbSupport` defaulting to `ompdSupport` (true). When that knob
# is on, the package puts `python3` into its `buildInputs` (not
# `nativeBuildInputs`) to install the OMPD/GDB Python helper scripts.
# OMPD is the OpenMP-Debugging interface; the Python files are loaded
# by `gdb` at *debug* time, not link/run-time of consumer code.
#
# Two consequences of the wrong dep classification:
#
# 1. `python3` in `buildInputs` makes it a host-platform dep, so
#    consumers (any package linking `libomp.a`) propagate
#    `pkgsStatic.python3` into their closure — wasted ~50 MB and a
#    long Python build for code that never runs the GDB scripts.
#
# 2. On pkgsStatic-darwin, `python3-3.13.x` has `meta.broken = true`
#    (CPython doesn't link cleanly as fully-static on macOS — libffi
#    / ctypes have darwin-specific dynamic-loader hooks). Eval of
#    *any* package that pulls openmp (fftw, vid-stab, rubberband via
#    fftw, …) crashes with `Package python3-3.13.12 is marked as
#    broken`.
#
# Setting `ompdGdbSupport = false` removes `python3` from
# `buildInputs` (still present in `nativeBuildInputs` because the
# build runs Python at configure time — that's the legitimate use).
# We lose the ability to attach `gdb` with OMPD scripts to debug
# OpenMP parallelism — nobody in our consumer chain does that;
# they just want the runtime library.
#
# Upstream-fixable: moving `python3` from `buildInputs` to
# `nativeBuildInputs` in `pkgs/development/compilers/llvm/common/
# openmp/default.nix` would fix this without losing any feature
# (the scripts run on the build platform via gdb, not on the host).
# Reporting that as a nixpkgs issue is on the TODO list.
{ lib }:
pkgs:
pkgs.llvmPackages.openmp.override { ompdGdbSupport = false; }
