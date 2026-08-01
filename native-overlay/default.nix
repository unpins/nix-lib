# Each sibling is the native fix for the package it is named after: either a
# bare `{ lib }: pkgs: drv` or the self-declaring `{ autoWire, apply }` shape
# (see flake.nix, rawNativeFixes). `lib` is unpins-lib's extended lib.
{ lib }:
lib.importFixDir { dir = ./.; inherit lib; }
