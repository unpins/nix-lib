# darwin: dash's configure.ac translates `--enable-static` into
# `export LDFLAGS="-static"`. On darwin libSystem.a doesn't exist (only
# libSystem.dylib), so every AC_CHECK_LIB probe that exec's a link
# command afterwards fails — including the libedit probe that aborts
# the build with "Can't find libedit." Same family as htop's
# native/htop.nix darwin branch.
#
# Filter the flag like htop does. Dependency static linking still works
# via the per-input .a libraries pkgsStatic supplies; only libSystem
# remains implicitly-dynamic — matches the catalog's darwin policy.
{ lib }:
pkgs:
let p = pkgs.pkgsStatic; in
if p.stdenv.hostPlatform.isDarwin then
  p.dash.overrideAttrs (oa: {
    configureFlags = p.lib.filter (f: f != "--enable-static") (oa.configureFlags or [ ]);
  })
else
  p.dash
