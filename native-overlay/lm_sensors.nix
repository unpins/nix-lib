# pkgsStatic.lm_sensors, for the programs that link libsensors.a (htop).
#
# 1. Config path. nixpkgs builds with ETCDIR=$out/etc, so libsensors.a reads
#    `<store>/etc/sensors3.conf` and every binary linking it carries a store
#    path. A self-contained binary reads the host's config, as upstream does
#    (`ETCDIR := /etc`): compile /etc in, keep installing to $out/etc.
#    (nixpkgs already points sensors.d at /etc.)
# 2. Engine only: lm_sensors builds its dependency files with `$(CC) -M -MG`,
#    which lists the compiler's system headers as make prerequisites. The
#    engine clang serves libc from a virtual root (`/__unpin_ziglib__/…`,
#    toolchain/unpin_clang_vfs.cpp) that does not exist on disk, so make stops
#    on `No rule to make target /__unpin_ziglib__/…/stdlib.h`. `-MM` leaves
#    system headers out, the libvpx fix (native-overlay/libvpx.nix) for the
#    same cause.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    pkgs.lm_sensors.overrideAttrs (oa: {
      postPatch = (oa.postPatch or "") + ''
        substituteInPlace Makefile --replace-fail '-DETCDIR="\"$(ETCDIR)\""' '-DETCDIR="\"/etc\""'
      '' + lib.optionalString (lib.isUnpinEngine pkgs) ''
        substituteInPlace Makefile --replace-fail '$(CC) -M -MG' '$(CC) -MM -MG'
      '';
    });
}
