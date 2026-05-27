# nixpkgs `pkgsStatic.game-music-emu` postFixup runs
# `remove-references-to -t cc $(readlink -f $out/lib/libgme.so)`. In
# pkgsStatic there is no `.so`; `readlink` returns empty and the
# `remove-references-to` fallback to `sed` with no input file errors
# `sed: no input files` → exit 1. With no `.so` to scrub, drop
# postFixup entirely. The `.a` produced by the build doesn't carry
# build-tool references either, so no replacement scrubber is needed.
{ lib }:
pkgs:
pkgs.game-music-emu.overrideAttrs (_oa: {
  postFixup = "";
})
