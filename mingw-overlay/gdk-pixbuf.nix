# gdk-pixbuf on mingw: drop `makeWrapper` from nativeBuildInputs.
#
# nixpkgs' `makeShellWrapper` setup-hook resolves
# `substitutions.shell = targetPackages.runtimeShell` eagerly at
# eval time. When cross-building gdk-pixbuf for mingw, that pulls
# bash-x86_64-w64-mingw32, which doesn't build cleanly (bash 5.3
# config.h emits `#define uid_t int / gid_t int / clock_t long`
# that conflict with mingw <sys/types.h>).
#
# Per gdk-pixbuf upstream's own comment, `gdk-pixbuf-thumbnailer is
# not wrapped` — i.e. the only reason makeWrapper is in the inputs
# at all is dead weight on cross-mingw. Drop it; nothing in the
# final install gets a wrapper anyway, and our consumer
# (`pkgsStatic.librsvg`) only needs the .pc + .a + headers.
{ lib }:
self: super:
super.gdk-pixbuf.overrideAttrs (old: {
  # Setup-hooks lack a `pname` attribute; match on `name` instead.
  nativeBuildInputs = builtins.filter
    (d: !(builtins.elem (d.name or d.pname or null) [
      "make-shell-wrapper-hook"
      "makeWrapper"
    ]))
    (old.nativeBuildInputs or [ ]);
})
