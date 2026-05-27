# harfbuzz on mingw static: `harfbuzz.pc` declares
# `Requires: freetype2, glib-2.0, graphite2` (public), but
# nixpkgs only propagates `graphite2`. `glib` and `freetype`
# sit in `buildInputs`. On dynamic Linux/Darwin builds the
# discrepancy is invisible — `.so` propagates DT_NEEDED — but
# static cross-mingw consumers (libass, pango, …) that probe
# `pkg-config harfbuzz` get "Package glib-2.0 not found"
# because `glib-2.0.pc` isn't in their `PKG_CONFIG_PATH`.
#
# Promote glib and freetype to propagatedBuildInputs so the
# public Requires claim is honest.
{ lib }:
self: super:
super.harfbuzz.overrideAttrs (old: {
  # Use `self.X` (post-overlay) — `super.glib` is the
  # nixpkgs-vanilla mingw glib, which still drags
  # libsysprof-capture and pulls a second `glib-x86_64-w64-
  # mingw32` derivation into the closure. `self.glib` picks
  # up our overlay (libsysprof dropped, pcre2 propagated).
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    self.glib
    self.freetype
  ];
  # Skip test binaries (hb-subset-fuzzer, hb-subset-threads,
  # …) — they statically link the full closure into many
  # ~150 MB `.exe` files, blowing through the build disk.
  # Nothing in our consumer chain (pango, librsvg, ffmpeg)
  # needs them.
  mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dtests=disabled" ];
})
