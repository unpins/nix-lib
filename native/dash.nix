# dash uses libedit for line editing in interactive mode. libedit links
# ncurses to look up terminal capabilities. Without our fallback list
# baked in, the binary depends on host terminfo (`/usr/share/terminfo`
# on Linux/macOS) — fine on a typical Ubuntu/Fedora/macOS desktop, but
# fails silently on Alpine without ncurses-terminfo-base, scratch
# containers, or any "minimal" environment.
#
# Swap libedit's `ncurses` arg for the embedded-fallbacks variant
# (database stays enabled, so host terminfo still wins when present —
# the fallback array is just a safety net for missing files).
{ lib }:
pkgs:
let
  p = pkgs.pkgsStatic;
  ncursesFB = lib.embedFallbackTerminfo p.ncurses;
in
p.dash.override {
  libedit = p.libedit.override { ncurses = ncursesFB; };
}
