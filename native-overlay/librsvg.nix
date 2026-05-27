# pkgsStatic.librsvg, two cross-platform fixes:
#
# 1. `+ libunwind` (non-mingw). librsvg's meson runs
#    `rustc --print=native-static-libs` which emits `-lunwind` for
#    musl targets, then calls `cc.find_library('unwind', static: true)`.
#    Dynamic builds resolve `_Unwind_*` via libgcc_s at runtime —
#    pkgsStatic forces the static probe. GCC libunwind 1.8.x suffices.
#    On mingw, Rust uses SEH and libunwind doesn't build (POSIX
#    ucontext.h); the mingw-overlay handles that path separately.
#
# 2. Propagate pango. librsvg-2.0.pc declares
#    `Requires.private: pangocairo`; consumers using
#    `pkg-config --static librsvg-2.0` (ffmpeg) abort with
#    "Package 'pangocairo' not found" without it. See
#    [[requires-private-static-cross]].
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.librsvg.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ])
    ++ lib.optionals (!isMinGW) [ pkgs.libunwind ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ pkgs.pango ];
})
