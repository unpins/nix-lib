# Same gnulib-getrandom / BCryptGenRandom missing -lbcrypt issue as gnused
# cross-mingw. Plus egrep/fgrep wrappers (shell scripts pointing at the
# nix-store grep path) are dropped — withAliases re-creates the names as
# UNPIN_META aliases that argv[0]-dispatch back to grep.exe.
{ lib }:
pkgs:
let
  cross = lib.mingwStaticCross pkgs;
  patched = cross.gnugrep.overrideAttrs (old: {
    NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lbcrypt";
    postInstall = (old.postInstall or "") + ''
      rm -f "$out/bin/egrep" "$out/bin/fgrep"
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "grep.exe";
    aliases = [ "egrep" "fgrep" ];
  }
  patched
