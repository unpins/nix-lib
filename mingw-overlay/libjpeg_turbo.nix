# libjpeg-turbo on mingw: nixpkgs ships `mingw-boolean.patch` which
# is malformed — it inserts three new `#if`/`#endif` pairs inside
# `#ifndef HAVE_BOOLEAN` but doesn't close that outer `#ifndef`.
# After the patch defines `HAVE_BOOLEAN` on Windows, the rest of
# `jmorecfg.h` (including `#define FAST_FLOAT float`) becomes
# unreachable, and `simd/x86_64/jsimd.c` blows up at compile time
# with `'FAST_FLOAT' undeclared`.
#
# Fix: add the missing `#endif` right before the JPEG_INTERNALS
# block (where the boolean section semantically ends in upstream),
# so HAVE_BOOLEAN gating no longer eats FAST_FLOAT and the rest of
# the header.
{ lib }:
self: super:
super.libjpeg_turbo.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    # Insert the missing close for the outer `#ifndef HAVE_BOOLEAN`
    # block right after the inner `typedef int boolean; #endif`
    # pair that used to be its body.
    sed -i '/^#if !defined(HAVE_BOOLEAN) && !defined(__RPCNDR_H__)$/,/^#endif$/ {
      /^#endif$/ a\
#endif
    }' src/jmorecfg.h
  '';
})
