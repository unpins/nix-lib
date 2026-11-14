# lm_sensors builds its dependency files with `$(CC) -M -MG`, which lists the
# compiler's system headers as make prerequisites. The engine clang serves libc
# from a virtual root (`/__unpin_ziglib__/…`, toolchain/unpin_clang_vfs.cpp)
# that does not exist on disk, so make stops on `No rule to make target
# /__unpin_ziglib__/…/stdlib.h`. `-MM` leaves system headers out of those files,
# the libvpx fix (native-overlay/libvpx.nix) for the same cause. Gated on the
# engine cc so a non-engine build is byte-identical.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if lib.isUnpinEngine pkgs
    then
      pkgs.lm_sensors.overrideAttrs (oa: {
        postPatch = (oa.postPatch or "") + ''
          substituteInPlace Makefile --replace-fail '$(CC) -M -MG' '$(CC) -MM -MG'
        '';
      })
    else pkgs.lm_sensors;
}
