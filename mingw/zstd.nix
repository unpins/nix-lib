# Mingw counterpart of native/zstd.nix. The cmake-based mingw build doesn't
# emit the unzstd/zstdcat/zstdmt symlinks that the unix install adds, so
# nothing to prune — just embed the multicall aliases as UNPIN_META.
{ lib }:
pkgs:
let cross = lib.mingwStaticCross pkgs; in
lib.withAliases pkgs
  {
    primary = "zstd.exe";
    aliases = [ "unzstd" "zstdcat" "zstdmt" ];
  }
  cross.zstd
