# nixpkgs builds coreutils with `--enable-single-binary=symlinks` already,
# so `$out/bin` ships one real `coreutils` multicall binary plus ~100
# per-command symlinks (ls, cat, cp, ...). unpins ships only the multicall
# — users dispatch via `coreutils --coreutils-prog=ls /tmp` or create
# their own basename symlinks. Drop the upstream symlinks post-install.
{ lib }:
pkgs:
pkgs.pkgsStatic.coreutils.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    find "$out/bin" -type l -delete
  '';
})
