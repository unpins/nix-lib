# gdk-pixbuf on mingw: drop `makeWrapper`. Its setup-hook eagerly resolves
# `targetPackages.runtimeShell`, pulling bash-x86_64-w64-mingw32 which
# doesn't build (config.h `uid_t`/`gid_t`/`clock_t` clash with mingw
# <sys/types.h>). Nothing here gets wrapped anyway.
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
