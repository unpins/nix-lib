# cosmocc can't produce .so and cosmo libc's wide-char symbols aren't on the
# standard <wchar.h> path ncurses expects. Build narrow-byte static ncurses via
# the two knobs (consumers tmux/htop/vim don't use wide-char terminal I/O):
#   - `enableStatic = true`    → .a only, drops shared-lib config
#   - `unicodeSupport = false` → skips wide-char path (else unresolved wint_t/wcwidth)
# `embedFallbackTerminfoOnly` bakes the curated terminfo into libtinfo.a and
# drops file-based lookups (the store terminfo path is meaningless on Windows,
# and Windows has no system terminfo dir).
{ lib }:
final: prev:
lib.embedFallbackTerminfoOnly (prev.ncurses.override {
  enableStatic = true;
  unicodeSupport = false;
})
