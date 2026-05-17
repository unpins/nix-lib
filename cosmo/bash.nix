# bash via mkPkgsCosmo for Windows-x86_64.
#
# nixpkgs 25.11's bash (5.3p3) + our cosmo ncurses/readline overlays
# build clean against cosmocc 4.0.2 without source patches —
# superconfigure's bash/readline/ncurses diffs that the playground
# version (cosmo-windows.nix using cosmoStdenv) carried turned out to
# be unnecessary at this cosmocc version.
#
# apelink converts the cosmo ELF to PE32+ in postFixup. After
# `rm $out/bin/bash`:
#   - nixpkgs' `sh -> bash` symlink (created in upstream postInstall)
#     dangles, stdenv's `noBrokenSymlinks` hook fails the build → rm it.
#   - `bashbug` is a shell script that upstream postFixup rewrites to
#     `#!$out/bin/bash`, which now doesn't exist; the script is useless
#     on Windows without that shebang resolving → rm it.
{ lib }:
final: prev:
let
  cs = import ../cosmocc.nix { pkgs = final.buildPackages; };
in
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  bash = prev.bash.overrideAttrs (oa: {
    postFixup = (oa.postFixup or "") + ''
      ${cs.cosmocc}/bin/apelink \
        -V ${toString cs.platformBits.windows} \
        -o $out/bin/bash.exe \
        $out/bin/bash
      rm -f $out/bin/bash $out/bin/sh $out/bin/bashbug
    '';
  });
} else { }
