# Strip terminfo from the mingw ncurses build + embed fallbacks.
#
# ncurses on Windows has two drivers: `tinfo` (terminfo-backed) and
# `win32console` (Console API, needs no terminal description). nixpkgs
# bakes the terminfo db at a nix store path and picks tinfo whenever
# `TERM` matches; under Git Bash/MSYS2 (`TERM=xterm-256color`) tinfo
# can't find that store path and degrades.
#
# `embedFallbackTerminfoOnly` bakes a curated fallback list into
# `_nc_fallback[]` and adds `--disable-database`, so the tinfo file
# lookup never runs: win32console handles cmd/PowerShell/conhost, the
# fallback array covers xterm/mintty/cygwin under Git Bash. Knock-on:
# nano.exe stops carrying the nix store `TERMINFO` strings.
{ lib }:
self: super:
lib.embedFallbackTerminfoOnly super.ncurses
