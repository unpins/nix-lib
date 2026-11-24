# The harfbuzz freetype links (see freetype.nix), so the set has one.
{ lib }:
self: super:
self.freetype.unpinHarfbuzz
