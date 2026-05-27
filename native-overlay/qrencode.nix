# nixpkgs qrencode pulls SDL2 in `nativeCheckInputs` to run the
# bundled tests during the build. SDL2 propagates `libglvnd` which
# is `meta.badPlatforms = lib.platforms.isStatic` on pkgsStatic (no
# GL on musl). The library itself doesn't need SDL2 — only the test
# binary does. Disable the check phase; mainline `libqrencode.a` +
# headers install fine.
{ lib }:
pkgs:
pkgs.qrencode.overrideAttrs (_oa: {
  doCheck = false;
})
