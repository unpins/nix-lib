# Two pkgsStatic / cross fixes:
#
# 1. `doCheck = false`. Upstream `nativeCheckInputs` pulls SDL2 to
#    visually preview QR rendering; SDL2 propagates `libglvnd` which
#    is `meta.badPlatforms = lib.platforms.isStatic` on pkgsStatic
#    (no GL on musl). The library + CLI don't need SDL2.
#
# 2. `postInstall` nukes `$out/lib/*.dylib` + relinks the `qrencode`
#    CLI against the static archive. pkgsStatic on darwin sets
#    `--disable-shared --enable-static` already, but libqrencode's
#    autotools setup builds both `.a` and `.dylib` anyway (LT_INIT
#    on darwin defaults to producing both), and libtool then picks
#    `.libs/libqrencode.dylib` for the CLI link → CI verifier
#    rejects the resulting binary for loading a non-system dylib.
#    Re-running `cc` by hand against `libqrencode.a` plus the
#    statically-linked libpng + zlib deps produces a clean binary.
#    The branch is gated on `isDarwin` so Linux pkgsStatic (where
#    only `.a` is produced) and mingw (where only `.a` ships as
#    well) bypass it as a no-op.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
pkgs.qrencode.overrideAttrs (oa: {
  doCheck = false;
  postInstall = (oa.postInstall or "") + lib.optionalString isDarwin ''
    # Strip the dynamic library shipped alongside (libqrencode's
    # libtool on darwin emits the `.dylib` regardless of
    # `--disable-shared` and silently skips the `.a` despite
    # `--enable-static`).
    rm -f $out/lib/libqrencode*.dylib

    # Build the static archive by hand from libtool's PIC `.lo`
    # outputs (already produced during compilePhase, live in `.libs/`).
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
  '';
})
