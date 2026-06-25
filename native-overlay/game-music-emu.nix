# nixpkgs' postFixup runs `remove-references-to ... $(readlink -f .../libgme.so)`,
# but pkgsStatic has no `.so` → empty readlink → `sed: no input files` → exit 1.
# Drop postFixup; the `.a` carries no build-tool refs to scrub anyway.
{ lib }:
pkgs:
pkgs.game-music-emu.overrideAttrs (_oa: {
  postFixup = "";
})
