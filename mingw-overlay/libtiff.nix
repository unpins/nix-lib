# libtiff on mingw static: `libtiff-4.pc` declares its codec libs as
# `Requires.private`; on static cross-mingw consumers (gdk-pixbuf,
# cairo, …) fail to resolve the transitive symbols at link time.
#
# 1. Disable niche codecs (lzma, zstd, webp) via cmake — no consumer
#    exercises them, and propagating libwebp recurses (libwebp ↔
#    libtiff). Filter the inputs to keep the derivation hash stable.
#
# 2. libdeflate is the always-on Deflate codec (`tif_zip.c`), so
#    promote it to public `Requires:` and propagate `self.libdeflate`.
#    See [[requires-private-static-cross]]. (Hardcoding `-ldeflate`
#    into `Libs:` doesn't help `--static` callers — cargo-c via
#    gdk-pixbuf-sys — which still follow `Requires.private`.)
{ lib }:
self: super:
super.libtiff.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-Dlzma=OFF"
    "-Dzstd=OFF"
    "-Dwebp=OFF"
  ];
  buildInputs = builtins.filter
    (d:
      let n = d.pname or d.name or ""; in
      n != "xz" && n != "zstd" && !lib.hasPrefix "libwebp" n)
    (old.buildInputs or [ ]);
  postInstall = (old.postInstall or "") + ''
    # Move libdeflate from Requires.private to public Requires.
    sed -i 's/^Requires\.private:  *zlib libdeflate libjpeg.*/Requires: libdeflate\nRequires.private: zlib libjpeg/' \
      $out/lib/pkgconfig/libtiff-4.pc
  '';
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    self.libdeflate
  ];
})
