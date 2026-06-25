# Two pkgsStatic / cross fixes:
#
# 1. `doCheck = false`: `nativeCheckInputs` pulls SDL2 → `libglvnd`, which is
#    `badPlatforms.isStatic` (no GL on musl). The lib + CLI don't need it.
#
# 2. Darwin libtool *sometimes* emits a `libqrencode.dylib` and links the CLI
#    against it → CI rejects the non-system dylib. Happens only when
#    `--disable-shared` doesn't take effect; otherwise no dylib (and no PIC
#    `.libs/*.o` to rebuild from). So gate the whole fixup on a dylib being
#    present: strip it, rebuild the `.a`, relink the CLI static. No dylib =
#    no-op. Gated isDarwin; linux/mingw emit only `.a`.
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
