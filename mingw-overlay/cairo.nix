# cairo on mingw, two fixes:
#
# 1. nixpkgs defaults `x11Support = true` (the recipe's `?`
#    fallback resolves to `... || true`), pulling libX11/libXext/
#    libXrender/libxcb into the closure. X11 doesn't exist on
#    Windows and libX11 itself fails the mingw build chain.
#    Disable both X backends via `.override`; consumers of cairo
#    on Windows use the `cairo_win32_*` surface APIs.
#
# 2. Demote `-Werror=incompatible-pointer-types` to warning.
#    `util/cairo-script/cairo-script-file.c:191` calls
#    `lzo2a_decompress` with mismatched pointer types — a
#    long-standing upstream bug. Linux/Darwin GCC default to
#    warning here, but mingw GCC 14 promotes it to error and
#    aborts the build of the cairo-script-interpreter utility.
#    The main `libcairo.a` (the only thing our closure needs)
#    builds clean either way.
{ lib }:
self: super:
(super.cairo.override {
  x11Support = false;
  xcbSupport = false;
}).overrideAttrs (old: {
  NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "")
    + " -Wno-error=incompatible-pointer-types";
  postInstall = (old.postInstall or "") + ''
    # pango's meson probe for "Cairo is built with FreeType and
    # FontConfig support" compiles a snippet that calls FcInit()
    # against the `cairo-ft` package. nixpkgs' `cairo-ft.pc`
    # only lists `cairo, freetype2` in `Requires:` — fontconfig
    # is present at build time (cairo's `--enable-fc` is on
    # because nixpkgs lists fontconfig in propagated deps), but
    # the .pc never advertises it, so the linker can't find
    # `FcInit`. Add fontconfig to `cairo-ft.pc Requires:` so
    # pango's probe passes.
    sed -i 's|^Requires: cairo, freetype2|Requires: cairo, fontconfig, freetype2|' \
      $out/lib/pkgconfig/cairo-ft.pc
    # cairo's public headers on Windows default to
    # `__declspec(dllimport)` unless `CAIRO_WIN32_STATIC_BUILD`
    # is defined. The cairo build itself defines it (visible
    # in the build line) but the installed `.pc` doesn't
    # advertise it, so consumers (pango's pangocairo-win32font.c)
    # link `libcairo.a` and get cascading `__imp_cairo_*`
    # undefined references. Inject the define into Cflags of
    # every cairo .pc so any consumer picks it up.
    for pc in $out/lib/pkgconfig/cairo*.pc; do
      sed -i 's|^Cflags:|Cflags: -DCAIRO_WIN32_STATIC_BUILD|' "$pc"
    done
  '';
})
