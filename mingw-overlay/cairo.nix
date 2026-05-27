# cairo cross-mingw, four fixes:
#
# 1. `x11Support = false; xcbSupport = false`. nixpkgs defaults
#    `x11Support = true` (recipe's `?` fallback), pulling libX11/
#    libXext/libXrender/libxcb. X11 doesn't exist on Windows and
#    libX11 itself fails the mingw build chain. Consumers use
#    `cairo_win32_*` surface APIs.
#
# 2. Demote `-Werror=incompatible-pointer-types`.
#    `util/cairo-script/cairo-script-file.c:191` calls
#    `lzo2a_decompress` with mismatched pointer types (upstream
#    bug). Mingw gcc 14 promotes to error; main `libcairo.a` is
#    unaffected, only the cairo-script-interpreter utility.
#
# 3. `cairo-ft.pc Requires` += fontconfig. nixpkgs' `cairo-ft.pc`
#    only lists `cairo, freetype2`; cairo's `--enable-fc` is on
#    (fontconfig in propagated deps) but `.pc` never advertises
#    it. Pango's meson probe compiles a snippet calling `FcInit()`
#    against `cairo-ft` and the linker can't resolve `FcInit`.
#
# 4. All `cairo*.pc Cflags` += `-DCAIRO_WIN32_STATIC_BUILD`.
#    Public headers default to `__declspec(dllimport)` unless
#    that macro is defined. The cairo build itself defines it but
#    the installed `.pc` doesn't propagate it, so consumers
#    (pango's `pangocairo-win32font.c`) link `libcairo.a` and get
#    `__imp_cairo_*` undef. See [[mingw-dllimport-static-pattern]].
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
