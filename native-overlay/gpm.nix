# pkgsStatic.gpm, for links' console mouse on Linux.
#
# Engine only: gpm builds its dependency file with `$(CC) -M`, which lists the
# compiler's system headers as make prerequisites. The engine clang serves libc
# from a virtual root (`/__unpin_ziglib__/…`, toolchain/unpin_clang_vfs.cpp)
# that does not exist on disk, so make stops on `No rule to make target
# /__unpin_ziglib__/…/stdio.h`. `-MM` leaves system headers out, the
# lm_sensors fix (native-overlay/lm_sensors.nix) for the same cause.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if lib.isUnpinEngine pkgs then
      pkgs.gpm.overrideAttrs (oa: {
        postPatch = (oa.postPatch or "") + ''
          substituteInPlace src/Makefile.in --replace-fail ' -M @CPPFLAGS@' ' -MM @CPPFLAGS@'
        '';
      })
    else pkgs.gpm;
}
