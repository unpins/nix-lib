# nano ships an `rnano` symlink that dispatches via argv[0] to enable
# restricted mode (same as `nano -R`). Drop the symlink at build time
# and embed it as UNPIN_META so unpin's installer recreates the alias.
#
# Plus: bake the curated terminfo fallback list into ncurses → nano
# renders correctly on hosts without `/usr/share/terminfo`. Host
# terminfo still wins when present (database stays enabled).
{ lib }:
pkgs:
let
  p = pkgs.pkgsStatic;
  ncursesFB = lib.embedFallbackTerminfo p.ncurses;
  pruned = (p.nano.override {
    ncurses = ncursesFB;
  }).overrideAttrs (old: {
    postInstall = (old.postInstall or "") + "\n" + ''
      for o in $outputs; do
        d="''${!o}"
        [ -L "$d/bin/rnano" ] && rm -f "$d/bin/rnano"
        true
      done
    '';
  });
in
lib.withAliases pkgs
  {
    primary = "nano";
    aliases = [ "rnano" ];
  }
  pruned
