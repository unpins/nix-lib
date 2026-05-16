# Auto-discovery aggregator for cosmo overlay fixes.
#
# Each sibling file is `{ lib }: final: prev: { ... }` — an overlay fragment.
# Default.nix flattens them into one overlay function by merging attrsets.
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
