# twolame on cross-mingw, static-only:
#
# `twolame.h` decorates every public function with
# `__declspec(dllimport)` on `_WIN32` unless `LIBTWOLAME_STATIC`
# is `#define`d before the include (header comment makes this
# explicit). Consumers (ffmpeg's `check_lib` for libtwolame)
# don't know about this knob, so the test program emits
# `__imp_twolame_init` refs that `libtwolame.a` can't satisfy.
#
# twolame doesn't install a `.pc` file (Makefile-only), so we
# can't inject the define through pkg-config's `Cflags:` like we
# do for chromaprint / libssh. Instead, patch the installed
# header to default to STATIC on `_WIN32` — there's no DLL in
# the cross output anyway (we build `--enable-static
# --disable-shared` globally).
{ lib }:
self: super:
super.twolame.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    sed -i 's|^#ifdef _WIN32$|#ifdef _WIN32\n#define LIBTWOLAME_STATIC|' \
      $out/include/twolame.h
  '';
})
