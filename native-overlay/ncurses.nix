# Pin ncurses' compiled-in DEFAULT terminfo dir to an FHS path. nixpkgs sets
# `--with-terminfo-dirs` to the FHS search list for static builds (so the binary
# doesn't depend on a store terminfo db) but leaves `--with-default-terminfo-dir`
# at `${out}/share/terminfo` — a /nix/store path baked into libtinfo's .rodata,
# which is a runtime-closure leak (and useless on the target host). Pinning it to
# `/usr/share/terminfo` (already in the search list) drops the leak with zero
# behavior change. Wired as an engine DEP fix so readline/libedit/htop all pick
# the fixed ncurses transitively (see flake.nix Layer C).
{ lib }:
scope:
scope.ncurses.overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-default-terminfo-dir=/usr/share/terminfo" ];
})
