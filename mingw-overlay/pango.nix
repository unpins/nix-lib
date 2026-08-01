# pango cross-mingw, three fixes:
#
# 1. `x11Support = false`. nixpkgs defaults it true on mingw, pulling
#    libXft → libX11, which doesn't cross-build (`modules/im/ximcp`
#    aborts); pango on Windows uses the Win32 font backend.
#
# 2. `-Dfontconfig=disabled -Dfreetype=disabled`. pango 1.57's
#    `meson.build:495` runs `cc.links()` against `cairo-ft`
#    unconditionally (despite docs claiming it skips on Windows); the
#    probe fails on the cascading `.pc` Requires chain. No fc on
#    Windows by design — DirectWrite handles font enumeration.
#
# 3. `+ fribidi + libthai` propagated. `pango.pc` requires them but
#    nixpkgs leaves them in plain buildInputs, so consumers (librsvg)
#    can't resolve pango.pc. `self.X` — see [[overlay-self-vs-super]].
{ lib }:
self: super:
(super.pango.override {
  x11Support = false;
}).overrideAttrs (oa: {
  mesonFlags = (oa.mesonFlags or [ ]) ++ [
    "-Dfontconfig=disabled"
    "-Dfreetype=disabled"
  ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [
    self.fribidi
    self.libthai
  ];
})
