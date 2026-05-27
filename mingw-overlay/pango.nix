# pango cross-mingw, three fixes:
#
# 1. `x11Support = false`. nixpkgs defaults `x11Support =
#    !isDarwin` (true on mingw), pulling libXft → libX11 →
#    modular xorg headers. libX11 doesn't cross-build for mingw
#    (`modules/im/ximcp` autotools subdir aborts); pango on
#    Windows uses the Win32 font backend.
#
# 2. `-Dfontconfig=disabled -Dfreetype=disabled`. pango 1.57's
#    `meson.build:495` unconditionally runs `cc.links()` on a
#    snippet using `cairo_ft_font_face_create_for_pattern` /
#    `FcPattern` against `cairo-ft`, regardless of platform. On
#    static cross-mingw the probe fails on the cascading `.pc`
#    Requires chain (cairo → fontconfig → expat → freetype →
#    bzip2 → brotli). Meson docs claim auto/disabled skips on
#    Windows; in 1.57 the check fires anyway. (No fc on Windows
#    by design — native font enumeration via DirectWrite.)
#
# 3. `+ fribidi + libthai` propagated. `pango.pc` declares
#    `Requires: glib-2.0, gobject-2.0, gio-2.0, fribidi,
#    libthai, harfbuzz, cairo`; nixpkgs only propagates
#    cairo/glib/harfbuzz, leaving fribidi+libthai in plain
#    buildInputs. Consumer (librsvg) sees pango.pc but can't
#    resolve fribidi/libthai → meson reports pango not found.
#    `self.X` (post-overlay) — see [[overlay-self-vs-super]].
{ lib }:
self: super:
(super.pango.override {
  x11Support = false;
}).overrideAttrs (old: {
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dfontconfig=disabled"
    "-Dfreetype=disabled"
  ];
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    self.fribidi
    self.libthai
  ];
})
