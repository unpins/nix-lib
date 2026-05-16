# libedit under cosmocc. cosmocc is clang-based and doesn't define
# `__STDC_ISO_10646__` (only stdc-predefs.h on GCC does — clang lacks
# the auto-include). libedit's chartype.h hard-errors without it via
# `#error wchar_t must store ISO 10646 characters`. nixpkgs has the
# same workaround gated on `isMusl && isClang`; we add the cosmo gate.
#
# Cosmo libc supplies wchar_t/wint_t for narrow byte-handling paths;
# the wide-character API exists but lives across libc/str/{str.h,
# unicode.h} rather than the standard <wchar.h>. libedit's wide-byte
# path uses just enough to compile when ISO_10646 is asserted.
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  libedit = prev.libedit.overrideAttrs (oa: {
    # examples/wtc1.c links against fwprintf which cosmocc doesn't
    # expose. Not part of the library; skip.
    configureFlags = (oa.configureFlags or [ ]) ++ [ "--disable-examples" ];

    env = (oa.env or { }) // {
      NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " [
        (oa.env.NIX_CFLAGS_COMPILE or "")
        "-D__STDC_ISO_10646__=201103L"
        # See libedit-cosmo-shim.h for the rationale (termios control
        # chars declared as runtime externs in cosmo's <termios.h>,
        # libedit needs literals for static-array initializers).
        "-include ${./libedit-cosmo-shim.h}"
      ];
    };
  });
} else { }
