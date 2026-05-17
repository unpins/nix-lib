# Upstream kmod ships a single multicall binary (`tools/kmod.c` does argv[0]
# dispatch) plus a symlink per tool (depmod, insmod, lsmod, modinfo, modprobe,
# rmmod). Mirrors the coreutils pattern: ship only the multicall, embed the
# applet names as an UNPIN_META block so unpin's installer can recreate the
# argv[0]-dispatch shims at install time.
{ lib }:
pkgs:
lib.withAliases pkgs
  {
    primary = "kmod";
    aliasesFromSymlinksIn = "bin";
  }
  pkgs.pkgsStatic.kmod
