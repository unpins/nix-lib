# Two pkgsStatic / cross fixes:
#
# 1. `doCheck = false`. Upstream `nativeCheckInputs` pulls SDL2 to
#    visually preview QR rendering; SDL2 propagates `libglvnd` which
#    is `meta.badPlatforms = lib.platforms.isStatic` on pkgsStatic
#    (no GL on musl). The library + CLI don't need SDL2.
#
# 2. On darwin libtool *sometimes* emits a `libqrencode.dylib` and
#    links the `qrencode` CLI against it → the CI verifier rejects the
#    binary for loading a non-system dylib. That happens when the build
#    leaves shared libs on (a top-level darwin pkgsStatic build whose
#    `--disable-shared` doesn't take effect). When it *does* take effect
#    (ffmpeg pulling qrencode as a pkgsStatic dep) libtool produces a
#    clean static `.a` + statically-linked CLI and emits no dylib — and
#    the PIC `.libs/*.o` the hand-rebuild needs don't exist. So gate the
#    whole fixup on a dylib being present: strip it, rebuild the `.a`
#    from libtool's `.libs/*.o`, relink the CLI static. No dylib =
#    no-op. Gated on isDarwin; Linux/mingw emit only `.a` and bypass it.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
pkgs.qrencode.overrideAttrs (oa: {
  doCheck = false;
  postInstall = (oa.postInstall or "") + lib.optionalString isDarwin ''
    if [ -n "$(find "$out/lib" -maxdepth 1 -name 'libqrencode*.dylib' -print -quit 2>/dev/null)" ]; then
      # libtool emitted a dynamic lib and linked the CLI against it.
      rm -f $out/lib/libqrencode*.dylib

      # Build the static archive by hand from libtool's PIC `.lo`
      # outputs (produced during compilePhase, live in `.libs/`).
      $AR rcs libqrencode.a \
        .libs/qrencode.o .libs/qrinput.o .libs/bitstream.o \
        .libs/qrspec.o  .libs/rsecc.o  .libs/split.o \
        .libs/mask.o    .libs/mqrspec.o .libs/mmask.o
      install -m644 libqrencode.a $dev/lib/libqrencode.a

      # Re-link `qrencode` CLI against the static archive. cc-wrapper's
      # NIX_LDFLAGS already carries `-L<libpng>/lib -L<zlib>/lib` from
      # buildInputs, so `-lpng16 -lz` resolves to the static archives.
      $CC -o $bin/bin/qrencode qrencode-qrenc.o \
        $dev/lib/libqrencode.a -lpng16 -lz
    fi
  '';
})
