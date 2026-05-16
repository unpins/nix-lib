# Upstream coreutils builds the multicall binary with
# `--enable-single-binary=symlinks`: one real `coreutils` in $out/bin plus a
# symlink per applet (ls, cat, cp, …). We ship only the multicall; the
# UNPIN_META block embedded by `lib.withAliases` tells unpin's installer to
# create the alias links itself at install time (argv[0]-dispatch via the
# multicall). Helper collects the applet names from the upstream symlinks
# before wiping them — single source of truth, no hand-maintained list.
{ lib }:
pkgs:
lib.withAliases pkgs
  {
    primary = "coreutils";
    aliasesFromSymlinksIn = "bin";
  }
  pkgs.pkgsStatic.coreutils
