# libsamplerate on mingw:
#
# 1. Clear upstream `meta.broken = isMinGW` — it gates on the shared-lib
#    `.def` failing `ld`, but mingwStaticCross suppresses the `.dll` build so
#    that path is never walked.
#
# 2. Drop `libsndfile` from buildInputs — only its sndfile-* CLI programs use
#    it, and those fail to link as `.exe` under `-all-static` (FLAC's chain
#    has DLL-only entry points). The lib itself doesn't need it.
{ lib }:
self: super:
super.libsamplerate.overrideAttrs (old: {
  meta = (old.meta or { }) // { broken = false; };
  buildInputs = [ ];
})
