# glib on mingw, two fixes bundled:
#
# 1. Drop `libsysprof-capture` (its `sysprof-capture-types.h` pulls POSIX
#    `<endian.h>`, missing on mingw libc → hard fail) and force
#    `-Dsysprof=disabled` unconditionally (nixpkgs only adds it
#    conditionally).
#
# 2. Promote `pcre2` to propagatedBuildInputs so the public
#    `Requires: libpcre2-8` in `glib-2.0.pc` is honest — static cross-mingw
#    consumers' `pkg-config glib-2.0` otherwise can't find `libpcre2-8.pc`
#    → meson "glib-2.0 found: NO" → whole closure fails to configure.
{ lib }:
self: super:
(super.glib.override {
  libsysprof-capture = super.emptyDirectory;
}).overrideAttrs (oa: {
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.pcre2 ];
  mesonFlags = (oa.mesonFlags or [ ]) ++ [ "-Dsysprof=disabled" ];
})
