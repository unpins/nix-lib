# Auto-discovery aggregator for mingw-overlay fixes (transitive deps consumed
# inside `mingwStaticCross`).
# Each sibling file is `{ lib }: self: super: drv` — an overlay fragment.
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
