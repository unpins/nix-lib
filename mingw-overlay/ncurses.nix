# Strip terminfo from the mingw ncurses build + embed fallbacks.
#
# Why: ncurses on Windows ships two drivers (selected at runtime by
# `--enable-term-driver`): `tinfo` for terminfo-backed terminals and
# `win32console` for the Windows Console API. The win32console driver
# talks `WriteConsoleW` / `SetConsoleMode` / `ReadConsoleInputA`
# directly — no terminal description needed, the Console API is the
# contract.
#
# By default nixpkgs builds the mingw ncurses with the terminfo
# database baked at `/nix/store/.../share/terminfo` and configures
# the runtime to pick the tinfo driver whenever `TERM` matches a
# known entry. Users running our binaries under Git Bash or MSYS2
# inherit `TERM=xterm-256color` and ncurses falls into the tinfo
# path, fails to find the nix store path, and degrades.
#
# `embedFallbackTerminfoOnly` solves both halves: bakes the curated
# fallback list into `_nc_fallback[]` AND adds `--disable-database`
# so the tinfo driver's file lookup never runs. ncurses falls
# through to the win32console driver when neither the fallback list
# nor the (now-disabled) file path resolves — the behaviour we want
# under cmd/PowerShell/conhost/Windows Terminal, with the fallback
# array covering xterm/mintty/cygwin/etc. when run from Git Bash.
#
# Knock-on: nano.exe stops carrying the `TERMINFO` / `TERMINFO_DIRS` /
# `/nix/store/.../share/terminfo` strings and works identically under
# every Windows shell.
{ lib }:
self: super:
lib.embedFallbackTerminfoOnly super.ncurses
