# libtiff on mingw static: `libtiff-4.pc` declares
# `Requires.private: zlib libdeflate libjpeg liblzma libzstd
# libwebp`. nixpkgs treats those as private `buildInputs`, so
# on static cross-mingw consumers (gdk-pixbuf, cairo, …) fail
# to find the transitive symbols at link time
# (`ZSTD_*`/`libdeflate_*`/`lzma_*`/`WebPDecode*`) — dynamic
# Linux/Darwin builds hide this because `.so`'s `DT_NEEDED`
# resolves them at runtime.
#
# Fix in two parts:
#
# 1. Disable the niche codecs (lzma, zstd, webp) via cmake.
#    None of our consumers (gdk-pixbuf, cairo, ffmpeg's
#    libtiff input) exercise them, and propagating libwebp
#    via overlay triggers an eval recursion (libwebp ↔
#    libtiff). Filter the corresponding inputs to keep the
#    derivation hash stable.
#
# 2. libdeflate is the always-on Deflate codec (`tif_zip.c`),
#    so it can't be dropped. Apply the standard mingw-static
#    Requires.private fix: promote `libdeflate` to public
#    `Requires:` so pkg-config emits `-ldeflate` even without
#    `--static`, and propagate `self.libdeflate` so its `.pc`
#    is in PKG_CONFIG_PATH for consumers. See
#    [[requires-private-static-cross]].
#
#    A previous iteration tried hardcoding `-L<libdeflate>/lib
#    -ldeflate` into libtiff-4.pc's `Libs:` — but consumers
#    that call pkg-config with `--static` (cargo-c via
#    librsvg's gdk-pixbuf-sys) still follow `Requires.private`
#    and abort because `libdeflate.pc` isn't reachable. The
#    propagate-based fix is uniform and covers both call sites.
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
