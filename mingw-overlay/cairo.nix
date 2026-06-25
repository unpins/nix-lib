# cairo cross-mingw, four fixes:
#
# 1. `x11Support/xcbSupport = false` — X11 doesn't exist on Windows and
#    libX11 fails the mingw build chain; consumers use `cairo_win32_*`.
#
# 2. Demote `-Werror=incompatible-pointer-types` — upstream bug in
#    `cairo-script-file.c:191` (`lzo2a_decompress`); only the script-
#    interpreter utility is affected, not `libcairo.a`.
#
# 3. `cairo-ft.pc Requires` += fontconfig — `--enable-fc` is on but the
#    .pc never advertises it, so pango's `FcInit()` probe fails to link.
#
# 4. All `cairo*.pc Cflags` += `-DCAIRO_WIN32_STATIC_BUILD` — headers
#    default to dllimport; .pc doesn't propagate the macro the build uses,
#    so consumers get `__imp_cairo_*` undef.
#    See [[mingw-dllimport-static-pattern]].
{ lib }:
self: super:
(super.cairo.override {
  x11Support = false;
  xcbSupport = false;
}).overrideAttrs (old: {
  NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "")
    + " -Wno-error=incompatible-pointer-types";
  postInstall = (old.postInstall or "") + ''
    sed -i 's|^Requires: cairo, freetype2|Requires: cairo, fontconfig, freetype2|' \
      $out/lib/pkgconfig/cairo-ft.pc
    for pc in $out/lib/pkgconfig/cairo*.pc; do
      sed -i 's|^Cflags:|Cflags: -DCAIRO_WIN32_STATIC_BUILD|' "$pc"
    done
  '';
})
