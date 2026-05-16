# nixpkgs's ncurses hardcodes `--with-shared` and `--enable-widec` in
# configureFlags. cosmocc can't produce .so, and cosmo libc's
# wide-character symbols (wcwidth, wint_t, …) aren't on the standard
# <wchar.h> path the ncurses sources expect — declarations are split
# across `libc/str/unicode.h` and `libc/str/str.h` which curses.h doesn't
# include. Cleanest workaround: strip both flags and build narrow-byte
# ncurses. UTF-8 still works at the terminal level — just not via wide
# char functions which the catalog's consumers (tmux/htop/vim) don't
# use for terminal I/O.
# nixpkgs's ncurses derivation already has the right knobs:
#   - `enableStatic = true`  → produces .a only, drops shared-lib config
#   - `unicodeSupport = false` → skips wide-char path (cosmo libc's
#     wchar.h split makes the widec build hit unresolved wint_t/wcwidth)
# Override the args; gate at the overlay level so buildPackages.ncurses
# (native glibc) stays vanilla.
#
# `embedFallbackTerminfoOnly` bakes the curated terminfo list into
# libtinfo.a and strips file-based lookups (matching mingw — the
# compiled-in `/nix/store/.../share/terminfo` path has no meaning on
# the user's Windows machine, and Windows has no system terminfo dir).
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  ncurses = lib.embedFallbackTerminfoOnly (prev.ncurses.override {
    enableStatic = true;
    unicodeSupport = false;
  });
} else { }
