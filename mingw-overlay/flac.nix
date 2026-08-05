# flac on mingw: headers default to `__declspec(dllimport)`, so static
# consumers (libsndfile, libopenmpt, ffmpeg) get `__imp_FLAC__*` undef.
# Inject `-DFLAC__NO_DLL` via the .pc `Cflags:` (plain external linkage)
# so every consumer picks it up automatically.
{ lib }:
self: super:
super.flac.overrideAttrs (oa: {
  postFixup = (oa.postFixup or "")
    + lib.withPcCflags "-DFLAC__NO_DLL" "$dev/lib/pkgconfig/*.pc";
})
