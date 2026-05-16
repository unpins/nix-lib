# Auto-discovery aggregator for mingw cross fixes.
# Each sibling file is `{ lib }: pkgs: drv` (host pkgs = native linux; the
# cross set is built via `lib.mingwStaticCross pkgs` inside each fix).
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
