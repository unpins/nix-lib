/* Shim for libedit under cosmocc.
 *
 * cosmocc's <termios.h> declares control-character macros as runtime
 * externs (`extern const int CSTART; #define CSTART CSTART`), which
 * compile but can't be used as static array initializers. libedit's
 * tty.c builds a default-key-binding table at compile time and needs
 * compile-time literals.
 *
 * Strategy: pull <termios.h> and <sys/ttydefaults.h> first so cosmo's
 * own values are in scope, then `#undef` + `#define` to literal
 * constants. The literals match the POSIX defaults (Ctrl-X = X^0x40,
 * `_POSIX_VDISABLE = 0xff`) — these are baseline values libedit uses
 * before any user remap, so the runtime behaviour is unchanged.
 *
 * Pushed in via NIX_CFLAGS_COMPILE="-include <this file>".
 */

#include <termios.h>
#include <sys/ttydefaults.h>

#undef _POSIX_VDISABLE
#define _POSIX_VDISABLE 0xff

/* ttydefaults.h in cosmo already gives us the right (CTRL-derived)
 * literal values for CSTART/CSTOP/CSUSP/CDISCARD/CWERASE/CREPRINT/
 * CLNEXT/CKILL/CEOF/CERASE/CINTR/CQUIT/CDSUSP/CBRK/CRPRNT/CFLUSH/
 * CEOL/CMIN/CTIME. But cosmo's termios.h *redefines* most of them
 * back to `extern const int X` after the fact. Force them back to
 * the ttydefaults literals so the tty.c initializer table compiles.
 */
#define CTRL_LIT_(x) ((x) ^ 0100)
#undef CINTR
#define CINTR    CTRL_LIT_('C')
#undef CQUIT
#define CQUIT    CTRL_LIT_('\\')
#undef CERASE
#define CERASE   CTRL_LIT_('?')
#undef CKILL
#define CKILL    CTRL_LIT_('U')
#undef CEOF
#define CEOF     CTRL_LIT_('D')
#undef CSTART
#define CSTART   CTRL_LIT_('Q')
#undef CSTOP
#define CSTOP    CTRL_LIT_('S')
#undef CSUSP
#define CSUSP    CTRL_LIT_('Z')
#undef CDSUSP
#define CDSUSP   CTRL_LIT_('Y')
#undef CLNEXT
#define CLNEXT   CTRL_LIT_('V')
#undef CDISCARD
#define CDISCARD CTRL_LIT_('O')
#undef CWERASE
#define CWERASE  CTRL_LIT_('W')
#undef CREPRINT
#define CREPRINT CTRL_LIT_('R')
#undef CEOL
#define CEOL     0
#undef CBRK
#define CBRK     CEOL
#undef CMIN
#define CMIN     1
#undef CTIME
#define CTIME    0

/* BSD-only constants cosmocc doesn't ship. libedit's tty.c references
 * them as defaults; values come from BSD sources. None of these are
 * exercised on Windows (no equivalent termios slot), so the value
 * just has to compile. */
#ifndef CERASE2
#define CERASE2  010      /* Ctrl-H, BSD secondary erase */
#endif
#ifndef CSWTCH
#define CSWTCH   0        /* SysV switch, not on BSD/cosmo */
#endif
#ifndef CDSWTCH
#define CDSWTCH  0
#endif
#ifndef CPGOFF
#define CPGOFF   0
#endif
#ifndef CSTATUS
#define CSTATUS  _POSIX_VDISABLE
#endif
