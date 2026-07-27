# pkgsStatic.libbluray: rename the leaked-global `dec_init`, which collides
# at static link with consumers that have their own `dec_init` (ffmpeg's
# `fftools/ffmpeg_dec.c`).
#
# Non-engine: `$OBJCOPY --redefine-sym` (not `--localize-symbol`) so the rename
# also rewrites sibling `disc.o`'s internal reference and libbluray stays
# self-consistent. Mach-O prefixes C symbols with `_`; the redefine is a
# literal symbol-table rewrite, so spell the underscore form on darwin.
#
# Engine: the archive members are LLVM BITCODE, which `llvm-objcopy` can't
# rewrite (`not recognized as a valid object file`). Rename `dec_init` at the
# SOURCE instead (it lives in exactly dec.h/dec.c/disc.c, no longer symbol has
# it as a prefix) so the collision-free name is baked into the bitcode. Same
# net effect, and it sidesteps the darwin `_`-prefix spelling entirely.
#
# fontconfig is kept (same as Linux): libbluray 1.4.1's meson + nixpkgs'
# `-Dauto_features=enabled` makes it REQUIRED. The consuming scope must
# provide a buildable darwin fontconfig (ffmpeg's does via
# nativeFixes.fontconfig).
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isEngine = lib.hasInfix "unpin-cc" (pkgs.stdenv.cc.name or "");
in
pkgs.libbluray.overrideAttrs (oa:
  if isEngine then {
    postPatch = (oa.postPatch or "") + ''
      sed -i 's/\bdec_init\b/bluray_internal_dec_init/g' \
        src/libbluray/disc/dec.h src/libbluray/disc/dec.c src/libbluray/disc/disc.c
    '';
  } else {
    postInstall = (oa.postInstall or "") + ''
      echo "renaming dec_init -> bluray_internal_dec_init in libbluray.a"
      $OBJCOPY ${if isDarwin
        then "--redefine-sym=_dec_init=_bluray_internal_dec_init"
        else "--redefine-sym=dec_init=bluray_internal_dec_init"} \
        $out/lib/libbluray.a
    '';
  })
