# libsamplerate on mingw:
#
# 1. Upstream `meta.broken = stdenv.hostPlatform.isMinGW` because shared-lib
#    output trips `ld` on a libtool-generated `.def` ("syntax error / file
#    format not recognized"). Under `mingwStaticCross` the static-libs adapter
#    suppresses the `.dll` build entirely, so the .def path is never walked.
#    Override the upstream gate to allow eval.
#
# 2. `buildInputs = [ libsndfile ]` upstream — libsndfile is only consumed
#    by the example/test programs (sndfile-*), not by `libsamplerate.a` itself.
#    Under mingwStaticCross, libsndfile's CLI programs (sndfile-info,
#    sndfile-convert, sndfile-metadata-{set,get}, sndfile-play) all fail to
#    link as `.exe` because the static adapter forces `-all-static` and FLAC's
#    transitive chain has DLL-only entry points. Drop libsndfile entirely;
#    the lib still builds and is what every consumer (rubberband, audacity,
#    …) actually uses.
{ lib }:
self: super:
super.libsamplerate.overrideAttrs (old: {
  meta = (old.meta or { }) // { broken = false; };
  buildInputs = [ ];
})
