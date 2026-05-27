# nixpkgs's svt-av1 defaults to `-DSVT_AV1_LTO=ON`, which makes the
# static archive ship only LTO IR (`__gnu_lto_slim` is the only symbol
# the regular `.symtab` carries). Non-LTO consumers (e.g. ffmpeg's
# pkg-config link probe) call `ld.bfd` without the LTO plugin loaded,
# so `cc test.c -lSvtAv1Enc` fails with `undefined reference to
# svt_av1_enc_init_handle`. cmake's last-wins semantics let us flip
# the flag with a tail `-D` append.
{ lib }:
pkgs:
pkgs.svt-av1.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DSVT_AV1_LTO=OFF" ];
})
