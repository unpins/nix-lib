# glib on mingw, two fixes bundled:
#
# 1. Drop `libsysprof-capture` from buildInputs. nixpkgs lists it
#    whenever `!isFreeBSD`, even though `-Dsysprof=disabled` is
#    already set on Windows. The header `sysprof-capture-types.h`
#    pulls in POSIX `<endian.h>` which is missing on the mingw
#    libc and the build hard-fails before glib even starts.
#    Also force-set `-Dsysprof=disabled` in mesonFlags — the
#    nixpkgs branch only adds it conditionally and we need it
#    unconditionally here.
#
# 2. Promote `pcre2` from `buildInputs` to `propagatedBuildInputs`.
#    nixpkgs' `glib-2.0.pc` declares `Requires: libpcre2-8` (a
#    public dependency in pkg-config terms), but pcre2 sits in
#    glib's private `buildInputs`. On dynamic Linux the
#    discrepancy is invisible — `DT_NEEDED` resolves
#    `libpcre2-8.so` at runtime. On static cross-mingw, however,
#    every consumer that runs `pkg-config --cflags glib-2.0`
#    transitively needs `libpcre2-8.pc` in its `PKG_CONFIG_PATH`,
#    and pkg-config aborts with "Package libpcre2-8 was not
#    found" → meson says "glib-2.0 found: NO" → the whole
#    closure (gdk-pixbuf, harfbuzz, pango, …) fails to
#    configure. Propagating pcre2 makes the public `Requires:`
#    honest.
{ lib }:
self: super:
(super.glib.override {
  libsysprof-capture = super.emptyDirectory;
}).overrideAttrs (old: {
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ self.pcre2 ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dsysprof=disabled" ];
})
