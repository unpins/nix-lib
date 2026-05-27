# pixman on mingw: meson builds the test executables (infinite-loop,
# trap-crasher, a1-trap-test, …) and links them against `libpng16.a`,
# but the link line omits `-lz` so static libpng's `deflate` / `crc32`
# / `inflate` symbols stay unresolved. Tests aren't consumed by any
# downstream (cairo, librsvg, ffmpeg), so disable them via meson.
{ lib }:
self: super:
super.pixman.overrideAttrs (old: {
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dtests=disabled"
  ];
})
