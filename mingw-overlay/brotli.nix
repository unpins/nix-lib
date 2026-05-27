# brotli on mingw static: `libbrotlidec.pc` and `libbrotlienc.pc`
# correctly declare `Requires.private: libbrotlicommon`, but
# consumers driven by libtool / autotools / cmake routinely
# call `pkg-config --libs` (without `--static`) which only emits
# `-lbrotlidec` (or -lbrotlienc) and drops the transitive
# `-lbrotlicommon`. On dynamic builds the .so resolves the
# missing `BrotliDefault*` / `_kBrotli*` symbols at runtime via
# DT_NEEDED; on static mingw the link fails with cascading
# undefined references.
#
# Promote `libbrotlicommon` from `Requires.private` to `Requires`
# in the dec/enc .pc files. The dependency is structurally
# always present in static builds, so the change is safe and
# eliminates the recurring brotli link failure across the entire
# closure (fontconfig, libbluray, freetype, harfbuzz, …).
{ lib }:
self: super:
super.brotli.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    for pc in $lib/lib/pkgconfig/libbrotlidec.pc $lib/lib/pkgconfig/libbrotlienc.pc; do
      sed -i 's/^Requires\.private: libbrotlicommon/Requires: libbrotlicommon/' "$pc"
    done
  '';
})
