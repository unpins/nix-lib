/*
 * Compatibility <sys/ttydev.h> for static ncurses on darwin.
 *
 * Verbatim copy of Apple's own legacy compat header (the SDK's
 * usr/include/sys/ttydev.h). ncurses' tinfo/lib_baudrate.c, on __APPLE__,
 * `#undef`s the termios B* speeds, `#define`s USE_OLD_TTY, then includes
 * <sys/ttydev.h> to pick up the small baud-rate indices (so `ospeed` keeps
 * its `short` type). Recent nixpkgs apple-sdk dropped this header, so the
 * sandboxed build can't find it (the host CommandLineTools SDK still has it).
 * We drop this copy into the ncurses source include/ tree (found via the
 * build's own -I../include); darwin-gated so Linux ncurses is untouched.
 */

#ifndef _SYS_TTYDEV_H_
#define _SYS_TTYDEV_H_

#ifdef USE_OLD_TTY
#define B0      0
#define B50     1
#define B75     2
#define B110    3
#define B134    4
#define B150    5
#define B200    6
#define B300    7
#define B600    8
#define B1200   9
#define B1800   10
#define B2400   11
#define B4800   12
#define B9600   13
#define EXTA    14
#define EXTB    15
#define B57600  16
#define B115200 17
#endif /* USE_OLD_TTY */

#endif /* !_SYS_TTYDEV_H_ */
