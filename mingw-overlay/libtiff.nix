# libtiff on mingw static: `libtiff-4.pc` declares its codec libs as
# `Requires.private`; on static cross-mingw consumers (gdk-pixbuf,
# cairo, …) fail to resolve the transitive symbols at link time.
#
# 1. lzma and zstd stay on. They were once turned off here as codecs
#    "no consumer exercises", which openjpeg disproves: opj_compress
#    takes TIFF as a documented input format, and without them the .exe
#    answers `ZSTD compression support is not configured` to files the
#    Linux and macOS builds of that same package read.
#
#    WebP stays off, for weight rather than for a loop — libwebp does
#    not link libtiff in this scope, so nothing recurses; it would just
#    put a whole image codec into every mingw consumer of libtiff for
#    the sake of a TIFF variant almost nothing writes.
#
# 2. libdeflate, liblzma and libzstd are the always-on codecs
#    (`tif_zip.c`, `tif_lzma.c`, `tif_zstd.c`), so promote them to
#    public `Requires:` and propagate them. See
#    [[requires-private-static-cross]]. (Hardcoding `-ldeflate` into
#    `Libs:` doesn't help `--static` callers — cargo-c via
#    gdk-pixbuf-sys — which still follow `Requires.private`.)
#
#    Public is what it takes, not merely propagated: gdk-pixbuf's meson
#    build reads only the public `Requires:` and then links libtiff.a
#    with an explicit list, so a codec left in `Requires.private` ends
#    as `undefined reference to lzma_end` at its link, not at ours.
{ lib }:
self: super:
super.libtiff.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-Dwebp=OFF"
  ];
  buildInputs = builtins.filter
    (d: !lib.hasPrefix "libwebp" (d.pname or d.name or ""))
    (oa.buildInputs or [ ]);
  postInstall = (oa.postInstall or "") + ''
    # Move the always-on codecs from Requires.private to public Requires,
    # and refuse to install a .pc where that silently did not happen — the
    # line's shape follows whatever codec set upstream enabled.
    pc=$out/lib/pkgconfig/libtiff-4.pc
    sed -i -E 's/^Requires\.private: +zlib libdeflate libjpeg ?(.*)$/Requires: libdeflate \1\nRequires.private: zlib libjpeg/' "$pc"
    for r in libdeflate liblzma libzstd; do
      grep -Eq "^Requires:.*\b$r\b" "$pc" || {
        echo "libtiff-4.pc does not require $r publicly:"; cat "$pc"; exit 1; }
    done
  '';
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [
    self.libdeflate
    self.xz
    self.zstd
  ];
})
