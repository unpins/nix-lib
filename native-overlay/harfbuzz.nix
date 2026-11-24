# The harfbuzz freetype links (see freetype.nix), so the scope has one.
{ lib }:
{
  autoWire = "static";
  apply = pkgs: pkgs.freetype.unpinHarfbuzz or pkgs.harfbuzz;
}
