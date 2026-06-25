# harfbuzz on mingw static: `harfbuzz.pc` declares `Requires: freetype2,
# glib-2.0, graphite2` but nixpkgs only propagates graphite2. Promote glib
# and freetype too, else static cross-mingw consumers' `pkg-config harfbuzz`
# fails with "Package glib-2.0 not found".
{ lib }:
self: super:
super.harfbuzz.overrideAttrs (old: {
  # `self.X` (post-overlay), not `super` — else vanilla mingw glib drags
  # libsysprof-capture and a second glib derivation into the closure.
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    self.glib
    self.freetype
  ];
  # Skip test binaries — they statically link the full closure into many
  # ~150 MB `.exe` files, blowing the build disk; no consumer needs them.
  mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dtests=disabled" ];
})
