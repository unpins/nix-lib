# Auto-discovery aggregator: each sibling is `{ lib }: pkgs: drv`, called by the
# standalone native build when `mkStandaloneFlake { name = "<pkg>"; }` resolves
# `<pkg>`. `lib` is unpins-lib's extended lib.
{ lib }:
let
  entries = builtins.readDir ./.;
  isFix = name: type:
    type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix";
  fixNames = lib.attrNames (lib.filterAttrs isFix entries);
in
lib.listToAttrs (map
  (file: {
    name = lib.removeSuffix ".nix" file;
    value = import (./. + "/${file}") { inherit lib; };
  })
  fixNames)
