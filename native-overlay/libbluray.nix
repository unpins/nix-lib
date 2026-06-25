# pkgsStatic.libbluray: rename the leaked-global `dec_init`, which collides
# at static link with consumers that have their own `dec_init` (ffmpeg's
# `fftools/ffmpeg_dec.c`). `--redefine-sym` (not `--localize-symbol`) so the
# rename also rewrites sibling `disc.o`'s internal reference and libbluray
# stays self-consistent. Mach-O prefixes C symbols with `_`; the redefine is
# a literal symbol-table rewrite, so spell the underscore form on darwin.
#
# fontconfig is kept (same as Linux): libbluray 1.4.1's meson + nixpkgs'
# `-Dauto_features=enabled` makes it REQUIRED. The consuming scope must
# provide a buildable darwin fontconfig (ffmpeg's does via
# nativeFixes.fontconfig).
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
pkgs.libbluray.overrideAttrs (oa: {
  postInstall = (oa.postInstall or "") + ''
    echo "renaming dec_init -> bluray_internal_dec_init in libbluray.a"
    $OBJCOPY ${if isDarwin
      then "--redefine-sym=_dec_init=_bluray_internal_dec_init"
      else "--redefine-sym=dec_init=bluray_internal_dec_init"} \
      $out/lib/libbluray.a
  '';
})
