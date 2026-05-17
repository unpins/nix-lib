# pkgsStatic.gnugrep ships bin/grep as ELF plus bin/{egrep,fgrep} as 1-line
# shell wrappers (`exec /nix/store/...-grep -E "$@"`). The wrappers hardcode
# the nix-store path of grep so they break the second the closure isn't
# present on the user's machine.
#
# GNU grep dispatches its mode from argv[0]: if the basename ends in `egrep`
# or `fgrep`, it implies `-E` / `-F`. So we drop the wrappers and register
# the names as UNPIN_META aliases; `unpin install grep` materialises them as
# argv[0]-shims that re-exec the grep binary with the original name preserved.
{ lib }:
pkgs:
let
  prepared = pkgs.pkgsStatic.gnugrep.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      rm -f "$out/bin/egrep" "$out/bin/fgrep"
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "grep";
    aliases = [ "egrep" "fgrep" ];
  }
  prepared
