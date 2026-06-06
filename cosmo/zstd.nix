# Make pkgsCross.cosmo.zstd build standalone. Three cosmo-specific snags:
#
# 1. zstd's CMake builds a *shared* library by default via its own
#    `ZSTD_BUILD_SHARED` option (independent of `BUILD_SHARED_LIBS`, which is
#    all `makeStaticLibraries` flips), and cosmocc can't emit `.so`.
#    `static = true` switches it to `ZSTD_BUILD_STATIC` only.
#
# 2. On x86_64 zstd's CMakeLists explicitly adds the hand-written
#    `lib/decompress/huf_decompress_amd64.S` to the source list. Under cosmocc
#    that file preprocesses to a symbol-less object (its body is guarded on
#    `__ELF__` / BMI2, which cosmo doesn't satisfy), and cosmocc's `fixupobj`
#    then aborts with "missing elf symbol table". The CMakeLists already has an
#    `else` branch — taken on non-asm targets — that instead defines
#    `-DZSTD_DISABLE_ASM` and ships zstd's C decompression path. Rewrite the
#    x86_64 branch to that, exactly as the MSVC branch already does: no asm
#    object, and the C path is functionally identical.
#
# 3. zstd drags `bashNonInteractive` (a buildInput) and `gnugrep` (baked into
#    its `zstdgrep`/`zstdless` wrapper scripts). Cross-building bash 5.3 under
#    cosmo fails on gcc-15's C23 `bool` keyword (`mkbuiltins.c`). We never ship
#    those wrappers and only want `libzstd`, so pull the build-host copies —
#    dead references at runtime, and the cosmo closure stays free of bash/grep
#    (this also drops pcre2, which only gnugrep pulls in).
#
# Gated on isCosmo so buildPackages.zstd (linux-gnu) keeps its
# cache.nixos.org hash; only pkgsCross.cosmo.zstd is touched.
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  zstd = (prev.zstd.override {
    static = true;
    bashNonInteractive = prev.buildPackages.bashNonInteractive;
    gnugrep = prev.buildPackages.gnugrep;
  }).overrideAttrs (oa: {
    postPatch = (oa.postPatch or "") + ''
      substituteInPlace build/cmake/lib/CMakeLists.txt --replace-fail \
        'set(DecompressSources ''${DecompressSources} ''${LIBRARY_DIR}/decompress/huf_decompress_amd64.S)' \
        'add_compile_options(-DZSTD_DISABLE_ASM)'
    '';
  });
} else { }
