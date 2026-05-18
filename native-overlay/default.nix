# Auto-discovery aggregator for native fixes.
#
# Each sibling file is `{ lib }: pkgs: drv` — the function the standalone
# native build calls when `mkStandaloneFlake { name = "<pkg>"; }` resolves
# `<pkg>`. lib here is unpins-lib's extended lib (nixpkgs.lib + our helpers
# like withDepsSharedPruned).
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
