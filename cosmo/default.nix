# Auto-discovery aggregator: each sibling is `{ lib }: final: prev: {...}`,
# merged into one overlay function.
{ lib }:
let
  entries = builtins.readDir ./.;
  isFix = name: type:
    type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix";
  fixNames = lib.attrNames (lib.filterAttrs isFix entries);
  fragments = map
    (file: import (./. + "/${file}") { inherit lib; })
    fixNames;
in
final: prev:
  lib.foldl' (acc: f: acc // (f final prev)) { } fragments
