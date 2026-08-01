# libthai on mingw static: `libthai.pc` declares
# `Requires.private: datrie-0.2`; consumers (pango) call pkg-config
# without `--static`, so `-ldatrie` drops and `trie_state_*` go
# unresolved. Promote it to public `Requires:` (same pattern as
# brotli/libtiff/fontconfig).
{ lib }:
self: super:
super.libthai.overrideAttrs (oa: {
  postInstall = (oa.postInstall or "") + ''
    sed -i 's/^Requires\.private:/Requires:/' \
      $dev/lib/pkgconfig/libthai.pc
  '';
  # Propagate so `datrie.pc` reaches consumers' PKG_CONFIG_PATH.
  # `self.libdatrie` (post-overlay) — `super` fails noBrokenSymlinks
  # on mingw (`trietool-0.2 -> trietool` dangling; real binary `.exe`).
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.libdatrie ];
})
