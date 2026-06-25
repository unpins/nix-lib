# nixpkgs svt-av1 defaults `-DSVT_AV1_LTO=ON`, so the static archive ships only
# LTO IR. Non-LTO consumers (ffmpeg's pkg-config link probe via `ld.bfd`
# without the LTO plugin) fail with `undefined reference to
# svt_av1_enc_init_handle`. Flip it off via cmake last-wins tail append.
{ lib }:
pkgs:
pkgs.svt-av1.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DSVT_AV1_LTO=OFF" ];
})
