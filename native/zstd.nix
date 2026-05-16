# Same shape as native/xz.nix: zstd is a multicall binary with `unzstd`,
# `zstdcat`, `zstdmt` as argv[0]-dispatch symlinks plus two shell scripts
# (`zstdgrep`, `zstdless`) that need a system shell + grep/less to work.
# Keep only the multicall and embed the aliases as UNPIN_META so unpin's
# installer recreates the dispatch links.
{ lib }:
pkgs:
let
  pruned = pkgs.pkgsStatic.zstd.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + "\n" + ''
      for o in $outputs; do
        d="''${!o}"
        [ -d "$d/bin" ] || continue
        find "$d/bin" -mindepth 1 -maxdepth 1 \
          ! -name 'zstd' ! -name 'zstd.exe' -delete
      done
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "zstd";
    aliases = [ "unzstd" "zstdcat" "zstdmt" ];
  }
  pruned
