# flac on mingw: headers default to `__declspec(dllimport)`, so static
# consumers (libsndfile, libopenmpt, ffmpeg) get `__imp_FLAC__*` undef.
# Inject `-DFLAC__NO_DLL` via the .pc `Cflags:` (plain external linkage)
# so every consumer picks it up automatically.
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
