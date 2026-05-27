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
# 2. (Darwin only) `libbluray.configure`'s autoconf has
#    `--without-fontconfig` but nixpkgs hard-wires fontconfig into
#    `buildInputs`. On darwin pkgsStatic the fontconfig closure
#    pulls `dejavu-fonts.minimal → fontforge → python3 → cross-bash`,
#    which fails to evaluate on aarch64-darwin cross-from-darwin
#    (the cross bash binary path is missing from the cross closure).
#    libbluray uses fontconfig only at runtime for menu/OSD font
#    discovery (BD-J UI rendering) — it's not a link-time
#    requirement of the `bd_*` C API. Consumers exercising only the
#    demuxer (e.g. ffmpeg's libbluray demuxer) never traverse the
#    fontconfig path. Pass `--without-fontconfig` AND filter
#    fontconfig out of `buildInputs` so the eval/build doesn't
#    traverse the dejavu chain.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
(pkgs.libbluray.override (
  if isDarwin
  then { fontconfig = pkgs.emptyDirectory; }
  else { }
)).overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ])
    ++ lib.optional isDarwin "--without-fontconfig";
  buildInputs = lib.optionals (!isDarwin) (oa.buildInputs or [ ])
    ++ lib.optionals isDarwin (builtins.filter
      (d: !(d.pname or null == "fontconfig"))
      (oa.buildInputs or [ ]));
  postInstall = (oa.postInstall or "") + ''
    echo "renaming dec_init -> bluray_internal_dec_init in libbluray.a"
    $OBJCOPY ${if isDarwin
      then "--redefine-sym=_dec_init=_bluray_internal_dec_init"
      else "--redefine-sym=dec_init=bluray_internal_dec_init"} \
      $out/lib/libbluray.a
  '';
})
