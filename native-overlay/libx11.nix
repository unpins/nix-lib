# pkgsStatic.libx11 under the engine: hand `XORG_PROG_RAWCPP` the build-host cpp.
#
# The probe writes `Does cpp redefine unix ?` and feeds it to the raw
# preprocessor to learn whether `-undef` stops the cpp predefining `unix`. Two
# things go wrong under the engine: the cc-wrapper's `cpp` reads its input from
# stdin and answers "no input files", and clang keeps `unix` defined even under
# `-undef`. Either way configure aborts with `<cpp> defines unix with or
# without -undef. I don't know what to do.`
#
# RAWCPP only preprocesses X11's host-independent locale/compose text at build
# time, so the build machine's gcc cpp (which honors `-undef`) produces the same
# data, and libX11 links in as the same static `.a`. Point at
# `buildPackages.stdenv.cc`, the cached native gcc wrapper — NOT `buildPackages.gcc`,
# whose `.gcc` attr builds a musl-target gcc from source.
#
# Set-wide because libx11 is never the package, always a transitive dep, and it
# arrives by several routes (cairo's xlib backend, libpulseaudio -> dbus, the X
# libraries). Eight flakes carried a hand-written copy of this override before
# it moved here: ddcutil, fastfetch, gvim, poppler-utils, sox, vorbis-tools,
# xvfb, xvnc.
#
# `autoWire = "musl"`, not "static": on darwin `buildPackages.stdenv.cc` is
# clang, which has the same `-undef` behaviour the probe trips over, so the
# redirect would buy nothing there.
{ lib }:
{
  autoWire = "musl";
  apply = pkgs: pkgs.libx11.overrideAttrs (_: {
    RAWCPP = "${pkgs.buildPackages.stdenv.cc}/bin/cpp";
  });
}
