# Promote `libbrotlicommon` from `Requires.private` to `Requires` in the
# dec/enc .pc files: consumers call `pkg-config --libs` without `--static`,
# dropping the transitive `-lbrotlicommon` → cascading undef refs on static
# mingw (no DT_NEEDED fallback).
{ lib }:
self: super:
super.brotli.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    for pc in $lib/lib/pkgconfig/libbrotlidec.pc $lib/lib/pkgconfig/libbrotlienc.pc; do
      sed -i 's/^Requires\.private: libbrotlicommon/Requires: libbrotlicommon/' "$pc"
    done
  '';
})
