# Un-pin libattr's compiled-in xattr.conf path. attr_copy_action.c hard-codes
# `ATTR_CONF = SYSCONFDIR "/xattr.conf"` and the Makefile compiles libattr with
# `-DSYSCONFDIR=$(sysconfdir)` = `${out}/etc` → a /nix/store path baked into
# libattr's .rodata (a runtime-closure leak, useless on the target host).
# Compile with `sysconfdir=/etc` (bare `#define ATTR_CONF "/etc/xattr.conf"`) but
# install the data file with `sysconfdir=${out}/etc` so the store still gets it
# and `make install` never writes to the real /etc. Consumers (coreutils' cp/mv
# -a) then look up the host's /etc/xattr.conf, or copy all xattrs if absent —
# the portable behavior. Wired as an engine DEP fix (coreutils → acl → attr;
# see flake.nix Layer C).
{ lib }:
{
  autoWire = "musl";
  apply = scope: scope.attr.overrideAttrs (oa: {
    makeFlags = (oa.makeFlags or [ ]) ++ [ "sysconfdir=/etc" ];
    installFlags = (oa.installFlags or [ ]) ++ [ "sysconfdir=${placeholder "out"}/etc" ];
  });
}
