# Two fixes to nixpkgs's `pkgsStatic.libbluray`:
#
# 1. (Universal) `libbluray.a` leaks internal helpers as globals
#    instead of `static`. `dec_init` in particular is a generic name
#    that collides at static link time with whatever the consumer
#    happens to call `dec_init` (e.g. ffmpeg's
#    `fftools/ffmpeg_dec.c`). `--localize-symbol dec_init` would
#    make it file-local to `dec.o`, but then sibling object `disc.o`
#    (which legitimately calls `dec_init` internally) loses access
#    and the build fails. Use `--redefine-sym` instead: rewrites the
#    definition *and* every internal reference inside every `.o` of
#    the archive, so libbluray stays self-consistent while the
#    renamed symbol no longer matches the consumer's `dec_init`.
#
#    Mach-O carries a leading underscore on C symbols (clang ABI),
#    ELF does not. `$OBJCOPY --redefine-sym` is a literal byte
#    rewrite over the symbol table, so the underscore form must be
#    spelled on darwin.
#
# 2. (History — fix removed 2026-06-03) An earlier nixpkgs revision
#    couldn't evaluate darwin pkgsStatic fontconfig (its
#    `--with-default-fonts=${dejavu_fonts.minimal}` pulled
#    `dejavu → fontforge → python3 → cross-bash`, and the cross bash
#    binary path was missing from the cross closure). We worked around
#    it by dropping fontconfig from libbluray on darwin
#    (`--without-fontconfig` + buildInputs filter).
#
#    On nixos-26.05 that no longer reproduces: the vanilla cross
#    `libbluray` (with fontconfig) evaluates cleanly, and the
#    dejavu→fontforge build tools are correctly sourced from
#    `buildPackages` (build host), not the cross target. Meanwhile
#    libbluray 1.4.1 switched to **meson** with nixpkgs'
#    `-Dauto_features=enabled`, which makes the (now optional)
#    fontconfig dependency REQUIRED — so dropping it now fails with
#    `ERROR: Dependency "fontconfig" not found`. So we simply keep
#    fontconfig (same as Linux). The consuming scope must provide a
#    buildable darwin fontconfig — ffmpeg's pkgsStaticScope already
#    does via `nativeFixes.fontconfig` (disables 2 flaky sysroot-path
#    tests that fail under pkgsStatic darwin).
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
