# ncurses' tinfo/lib_baudrate.c, on __APPLE__, `#undef`s the termios B* speeds,
# `#define`s USE_OLD_TTY, then includes <sys/ttydev.h> for the small baud-rate
# indices. Recent nixpkgs apple-sdk dropped that legacy compat header, so the
# sandboxed darwin build fails 'sys/ttydev.h file not found'. Drop Apple's own
# verbatim copy of the header into the source include/ tree, resolved via the
# build's existing `-I../include`.
#
# Unlike the other native-overlay fixes (which take the package `scope`), this is
# a leaf drv→drv transform: it's applied by `lib.embedFallbackTerminfoOnly` to the
# fallback ncurses ONLY, never to the set-wide ncurses. The USE_OLD_TTY path is
# reached only under `--disable-database` (the fallback build), so the plain
# ncurses never needs it — and overriding the set ncurses would re-hash apple-sdk
# (it embeds ncurses dev headers) and the whole darwin stdenv bootstrap.
{ lib }:
ncurses:
ncurses.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "")
    + lib.optionalString (ncurses.stdenv.hostPlatform.isDarwin or false) ''
    mkdir -p include/sys
    cp ${./darwin-ttydev.h} include/sys/ttydev.h
  '';
})
