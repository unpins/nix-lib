# pkgsCross.cosmo.zlib built `libz.a` into an output nothing propagates, so
# every cosmo consumer silently lost gzip: the header probe passed and the
# link probe failed.
#
# `shared` defaults to `!isStatic`, and the cosmo platform is not marked
# static, so zlib went looking for a `.so` cosmocc cannot emit -- leaving
# `$out/lib` empty -- and `splitStaticOutput` (which follows `shared`) put
# `libz.a` in a separate `static` output that only a direct reference reaches.
# Turning `shared` off collapses both: no `.so` attempted, `libz.a` in
# `$out/lib`.
#
# Measured on links (`checking for inflate in -lz... no`, `Supported
# compression: BROTLI ZSTD BZIP2 LZMA` with no ZLIB) and on e2fsprogs'
# libarchive (`could not find a suitable version of zlib (>= 1.2.1)`).
{ lib }:
final: prev:
prev.zlib.override { shared = false; }
