# cosmocc (clang) doesn't define `__STDC_ISO_10646__` (only GCC's
# stdc-predefs.h does), so libedit's chartype.h hard-errors. nixpkgs applies
# the same `-D__STDC_ISO_10646__` workaround, but only on `isMusl && isClang`.
{ lib }:
final: prev:
prev.libedit.overrideAttrs (oa: {
  # examples/ link fwprintf, which cosmocc doesn't expose; not part of the lib.
  configureFlags = (oa.configureFlags or [ ]) ++ [ "--disable-examples" ];

  env = (oa.env or { }) // {
    NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " [
      (oa.env.NIX_CFLAGS_COMPILE or "")
      "-D__STDC_ISO_10646__=201103L"
      # cosmo's <termios.h> declares control chars as runtime externs, but
      # libedit needs literals for static-array initializers; see the shim.
      "-include ${./libedit-cosmo-shim.h}"
    ];
  };
})
