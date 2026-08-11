# libbluray's meson.build assumes mingw means gcc: on any non-MSVC windows it
# unconditionally does `cc.find_library('ssp')`, which is required by default,
# so configure stops with "C shared or static library 'ssp' not found".
#
# `libssp.a` is a GCC artifact, not a mingw-w64 one — measured: nixpkgs'
# mingw-w64 ships no libssp.a (only libsspicli.a, which is SSPI), while
# x86_64-w64-mingw32-gcc ships libssp.a + libssp_nonshared.a. Upstream
# mingw-w64 folds the ssp/*_chk.c sources into libmingwex instead. So under a
# clang toolchain there is nothing to find, and inventing one would be the same
# mistake as inventing libgcc over compiler-rt — llvm-mingw's documented answer
# to this class is to fix the build script.
#
# Dropping the check is safe here: SSP is off on mingw (nixpkgs' hardening flag
# is a no-op for this platform), so nothing references __stack_chk_fail.
{ lib }:
self: super:
super.libbluray.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace meson.build \
      --replace-fail "extra_dependencies += cc.find_library('ssp')" ""
  '';
})
