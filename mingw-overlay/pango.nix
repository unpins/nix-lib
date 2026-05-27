# pango on mingw, two fixes:
#
# 1. nixpkgs defaults `x11Support = !isDarwin`, which is true
#    on mingw and drags libXft → libX11 → modular xorg headers
#    into the closure. libX11 itself doesn't cross-build for
#    mingw (the `modules/im/ximcp` autotools subdir aborts),
#    and X11 has no meaning on Windows anyway — pango on
#    Windows uses the Win32 font backend.
#
# 2. Force `-Dfontconfig=disabled`. pango 1.57's meson.build:495
#    unconditionally runs `cc.links()` on a test using
#    `cairo_ft_font_face_create_for_pattern`/`FcPattern` against
#    `cairo-ft` regardless of platform. On static cross-mingw the
#    link test fails because of the indirect cascading `.pc`
#    Requires chain (cairo → fontconfig → expat → freetype →
#    bzip2 → brotli), some of which aren't in pango's
#    `PKG_CONFIG_PATH`. The meson option docs explicitly state
#    "Passing 'auto' or 'disabled' disables fontconfig on
#    Windows" — but in 1.57 it fires the check anyway. Force
#    the cairo backends path to skip ft+fontconfig and use the
#    Win32 backend only. (Our consumers don't need fc on
#    Windows; native font enumeration is done via DirectWrite.)
{ lib }:
self: super:
(super.pango.override {
  x11Support = false;
}).overrideAttrs (old: {
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dfontconfig=disabled"
    "-Dfreetype=disabled"
  ];
  # `pango.pc` lists `Requires: glib-2.0, gobject-2.0, gio-2.0,
  # fribidi, libthai, harfbuzz, cairo`. nixpkgs' base pango only
  # propagates cairo/glib/harfbuzz; fribidi and libthai are in
  # the (non-propagated) buildInputs. Consumers like librsvg
  # then see pango.pc but can't resolve `fribidi` / `libthai`
  # in `PKG_CONFIG_PATH` and `meson` reports
  # "Run-time dependency pango found: NO".
  # Add the missing two so the .pc transitive graph closes.
  # `self.X` not `super.X` to pick up post-overlay versions
  # (see [[overlay-self-vs-super]]).
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    self.fribidi
    self.libthai
  ];
})
