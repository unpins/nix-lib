# dash via mkPkgsCosmo for Windows-x86_64.
#
# nixpkgs 25.11 ships dash 0.5.12 — same version superconfigure/playground
# validated, no pin needed (unlike coreutils). The playground POC
# (cosmoStdenv direct) compiled clean *without* superconfigure's
# minimal.diff; we follow the same route here and only reach for the
# diff if cosmocc trips on `mbstate_t = {}` empty-init.
#
# Only two delta vs the nixpkgs derivation:
#   - drop libedit (no cosmo build of it; dash --without-libedit just
#     loses line editing in interactive mode, which is fine for a
#     scripting shell).
#   - apelink ELF -> PE32+ in postFixup so `bin/dash.exe` is what gets
#     stripped/joined upstream.
{ lib }:
final: prev:
let
  cs = import ../cosmocc.nix { pkgs = final.buildPackages; };
in
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  dash = (prev.dash.overrideAttrs (oa: {
    # nixpkgs adds libedit as a buildInput and pkg-configs `--libs --static`
    # for it under pkgsStatic. cosmo has neither libedit nor pkg-config
    # for it; drop both. preConfigure is the LIBS export — nuke entirely
    # since we no longer need libedit.
    buildInputs = [ ];
    configureFlags = [ "--without-libedit" ];
    preConfigure = "";

    env = (oa.env or { }) // {
      NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " [
        (oa.env.NIX_CFLAGS_COMPILE or "")
        "-Wno-implicit-function-declaration"
      ];
    };

    # apelink converts the single-arch cosmo ELF in-place to a PE32+
    # Windows binary. -V picks the Windows half from the polyglot
    # platform mask. Runs in postFixup (not postBuild) to mirror the
    # coreutils pattern: any later passes work against the .exe.
    postFixup = (oa.postFixup or "") + ''
      ${cs.cosmocc}/bin/apelink \
        -V ${toString cs.platformBits.windows} \
        -o $out/bin/dash.exe \
        $out/bin/dash
      rm -f $out/bin/dash
    '';
  }));
} else { }
