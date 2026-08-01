# pixman on mingw: meson links its test executables against
# `libpng16.a` but omits `-lz`, leaving static libpng's `deflate`/
# `crc32`/`inflate` unresolved. No downstream needs the tests, so
# disable them.
{ lib }:
self: super:
super.pixman.overrideAttrs (oa: {
  mesonFlags = (oa.mesonFlags or [ ]) ++ [
    "-Dtests=disabled"
  ];
})
