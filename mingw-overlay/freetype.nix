# No run-time harfbuzz: without harfbuzz at build time, configure's `auto`
# falls back to LoadLibrary("libharfbuzz-0.dll") in the autohinter, which
# would load whatever DLL of that name is on the search path (see
# native-overlay/freetype.nix).
{ lib }:
self: super:
super.freetype.overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-harfbuzz=no" ];
})
