# nano cross-mingw pulls `pkgsCross.mingwW64.file` for libmagic; `file` itself
# fails to cross (readcdf.c hits the same upstream bug the unpins/file repo
# patches over). `file = null` falls back to extension-based syntax detection.
#
# The remaining clash is in browser.c: nano's bundled gnulib `#define DIR
# struct gl_directory` so its `dirfd` module works, but leaves `rewinddir`
# unreplaced. mingw's `<dirent.h>` declaration `rewinddir(mingw_DIR *)` thus
# coexists with `dir` having type `struct gl_directory *`. The patch swaps
# rewinddir for closedir+opendir under `_WIN32` only — smaller blast radius
# than patching gnulib, native builds unchanged.
{ lib }:
pkgs:
let
  cross = lib.mingwStaticCross pkgs;
  patched = (cross.nano.override { file = null; }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./nano-mingw-rewinddir.patch ];
    # nano's Makefile links nano.exe with direct gcc (no libtool), so `-static`
    # is the right flag — `-all-static` is libtool-specific and gcc rejects it.
    makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-static" ];
    # mingw ncurses headers default to `__declspec(dllimport)` for COLS/wmove/
    # waddnstr/etc., which leaves `__imp_*` references for the static link.
    # `NCURSES_STATIC` flips them back to plain extern declarations.
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " (
        (lib.optional (old ? env && old.env ? NIX_CFLAGS_COMPILE)
          old.env.NIX_CFLAGS_COMPILE)
        ++ [ "-DNCURSES_STATIC" ]);
    };
    # nano's install rule creates `bin/rnano -> bin/nano`, but mingw's binary
    # is `nano.exe` — the symlink dangles and trips noBrokenSymlinks. Drop it;
    # withAliases recreates it as UNPIN_META.
    postInstall = (old.postInstall or "") + "\n" + ''
      for o in $outputs; do
        d="''${!o}"
        [ -L "$d/bin/rnano" ] && rm -f "$d/bin/rnano"
        true
      done
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "nano.exe";
    aliases = [ "rnano" ];
  }
  patched
