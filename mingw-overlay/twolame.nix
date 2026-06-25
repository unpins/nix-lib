# twolame on cross-mingw, static-only:
#
# `twolame.h` marks public functions `__declspec(dllimport)` on
# `_WIN32` unless `LIBTWOLAME_STATIC` is defined first; consumers
# (ffmpeg's `check_lib`) don't set it, so the probe emits
# `__imp_twolame_init` refs `libtwolame.a` can't satisfy. twolame
# installs no `.pc`, so we can't inject via `Cflags:` (as for
# chromaprint/libssh) — patch the header to default STATIC on
# `_WIN32` instead (no DLL in the cross output anyway).
{ lib }:
self: super:
super.twolame.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    sed -i 's|^#ifdef _WIN32$|#ifdef _WIN32\n#define LIBTWOLAME_STATIC|' \
      $out/include/twolame.h
  '';
})
