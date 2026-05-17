# gawk via mkPkgsCosmo for Windows-x86_64 (mingw is impractical — gawk's
# unix-configure path on mingw misses pc/popen.c + pc/socket.c + several
# header forwards that the gawk pc/ port wires in, and replicating that in
# Nix would be a full secondary build).
#
# cosmocc gaps:
#   * extension/ subdir builds dynamic plugins (filefuncs.dll etc.). Useless
#     for the single-binary contract AND collides with cosmo's stdlib.h
#     declaration of BSD `index()` shadowed by `static int index = -1;` in
#     extension/stack.c. `--disable-extensions` skips the subbuild.
#   * cosmocc lacks <readline/readline.h>; configure picks `--without-readline`
#     fine.
#
# apelink -V 4 strips the polyglot down to PE32+ for the .exe deliverable.
{ lib }:
final: prev:
let
  cs = import ../cosmocc.nix { pkgs = final.buildPackages; };
in
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  gawk =
    let
      patched = prev.gawk.overrideAttrs (oa: {
        configureFlags = (oa.configureFlags or [ ]) ++ [ "--disable-extensions" ];

        postInstall = (oa.postInstall or "") + ''
          rm -rf "$out/libexec" "$out/share/awk" "$out/lib/gawk"
          rmdir "$out/lib" 2>/dev/null || true
          # Drop the awk → gawk symlink — withAliases re-embeds it
          rm -f $out/bin/awk
        '';

        postFixup = (oa.postFixup or "") + ''
          ${cs.cosmocc}/bin/apelink \
            -V ${toString cs.platformBits.windows} \
            -o $out/bin/gawk.exe \
            $out/bin/gawk
          rm -f $out/bin/gawk
        '';
      });
    in
    lib.withAliases final
      {
        primary = "gawk.exe";
        aliases = [ "awk" ];
      }
      patched;
} else { }
