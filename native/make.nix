# nixpkgs ships GNU make as `gnumake`; bridge the name mismatch so unpins/make
# can be a one-liner flake with `name = "make"`.
{ lib }:
pkgs:
pkgs.pkgsStatic.gnumake
