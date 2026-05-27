# libthai on mingw static: `libthai.pc` declares
# `Requires.private: datrie-0.2`. Consumers (pango) call
# pkg-config without `--static`, so `-ldatrie` is dropped
# from the link line and `trie_state_*`/`trie_state_walk`
# resolve to nothing.
#
# Same fix pattern as `brotli.nix` / `libtiff.nix` /
# `fontconfig.nix`: promote `Requires.private` → public
# `Requires:` so pkg-config emits `-ldatrie` regardless of
# `--static`. libdatrie is already in nixpkgs' libthai
# buildInputs; the .pc just needs to advertise it.
{ lib }:
self: super:
super.libthai.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    sed -i 's/^Requires\.private:/Requires:/' \
      $dev/lib/pkgconfig/libthai.pc
  '';
  # The promoted `Requires:` only resolves when `datrie.pc`
  # is in `PKG_CONFIG_PATH`. Propagate libdatrie so pango (the
  # consumer) gets it via setup-hook.
  # `self.libdatrie` (post-overlay) — `super.libdatrie` is the
  # vanilla pkg that fails noBrokenSymlinks on mingw because
  # `trietool-0.2 -> trietool` is dangling (real binary is
  # `.exe`).
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ self.libdatrie ];
})
