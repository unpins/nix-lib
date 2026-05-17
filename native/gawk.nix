# pkgsStatic.gawk ships:
#   bin/gawk       — the ELF, ~900 KB stripped
#   bin/awk → gawk — symlink
#   libexec/awk/{grcat,pwcat} — small helpers invoked by the awklib library
#                               scripts in share/awk
#   share/awk/*.awk — library scripts (passwd.awk, group.awk, ftrans.awk, …)
#   lib/gawk/*.a    — extension modules (filefuncs, readdir, time, …) built
#                     as static archives because pkgsStatic blocks shared
#                     libs. They are dead weight: gawk can only `@load` a
#                     shared module, never a .a.
#
# `--disable-extensions` skips the extension/ subbuild entirely. We then
# drop libexec/ and share/awk so the published artifact is gawk-only.
# `awk` is registered as an UNPIN_META alias; gawk doesn't switch behaviour
# on argv[0], so both names invoke the same binary.
{ lib }:
pkgs:
let
  prepared = (pkgs.pkgsStatic.gawk.override { interactive = false; }).overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-extensions" ];
    postInstall = (old.postInstall or "") + ''
      rm -rf "$out/libexec" "$out/share/awk" "$out/lib/gawk"
      rmdir "$out/lib" 2>/dev/null || true
      # `awk → gawk` symlink shipped by upstream; lib.withAliases re-embeds
      # it via UNPIN_META, so drop the file artifact to keep the release
      # tarball at exactly one executable.
      rm -f "$out/bin/awk"
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "gawk";
    aliases = [ "awk" ];
  }
  prepared
