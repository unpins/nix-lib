# flac on mingw: by default the installed headers decorate every
# public symbol with `__declspec(dllimport)`, expecting consumers to
# resolve them through a `flac.dll` at runtime. Static consumers
# (libsndfile, libopenmpt, ffmpeg via `--enable-libflac`) end up with
# undefined `__imp_FLAC__*` references at link time because the .a
# doesn't carry the DLL import thunks.
#
# Defining `FLAC__NO_DLL` before including any FLAC header switches
# the prototypes to plain external linkage. Inject it via the `.pc`
# `Cflags:` so every consumer picks it up automatically — they'd
# otherwise each need their own `-DFLAC__NO_DLL`.
{ lib }:
self: super:
super.flac.overrideAttrs (old: {
  postFixup = (old.postFixup or "") + ''
    for pc in $dev/lib/pkgconfig/*.pc; do
      [ -f "$pc" ] || continue
      if ! grep -q 'FLAC__NO_DLL' "$pc"; then
        sed -i 's|^Cflags:|Cflags: -DFLAC__NO_DLL|' "$pc"
      fi
    done
  '';
})
