# pkgsCross.cosmo.zstd, three cosmo snags:
#
# 1. zstd's CMake builds shared by default via its own `ZSTD_BUILD_SHARED`
#    (not the `BUILD_SHARED_LIBS` that makeStaticLibraries flips), and cosmocc
#    can't emit `.so`. `static = true` → `ZSTD_BUILD_STATIC` only.
#
# 2. On x86_64 the CMakeLists adds `huf_decompress_amd64.S`, which under cosmocc
#    preprocesses to a symbol-less object (guarded on `__ELF__`/BMI2) → fixupobj
#    aborts "missing elf symbol table". Take the existing `else` branch
#    (`-DZSTD_DISABLE_ASM`, C decompression path), as the MSVC branch does.
#
# 3. zstd drags bashNonInteractive + gnugrep (for zstdgrep/zstdless wrappers we
#    never ship); cross-building bash 5.3 under cosmo fails on gcc-15's C23 bool.
#    Use build-host copies — dead refs at runtime, keeps bash/grep/pcre2 out of
#    the cosmo closure.
{ lib }:
final: prev:
(prev.zstd.override {
  static = true;
  bashNonInteractive = prev.buildPackages.bashNonInteractive;
  gnugrep = prev.buildPackages.gnugrep;
}).overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace build/cmake/lib/CMakeLists.txt --replace-fail \
      'set(DecompressSources ''${DecompressSources} ''${LIBRARY_DIR}/decompress/huf_decompress_amd64.S)' \
      'add_compile_options(-DZSTD_DISABLE_ASM)'
  '';
})
