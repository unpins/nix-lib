# Fold openssl's canonical packaging delta (lib.retargetOpenssl — OPENSSLDIR/
# ENGINESDIR/MODULESDIR retargeted off /nix/store to /etc/ssl, CT re-enabled,
# c_rehash dropped without the engine-breaking makeWrapper compile) into every
# engine consumer's openssl, so none of them re-roll it by hand. dnsutils was the
# lone engine consumer and had drifted into a partial copy that omitted the
# c_rehash drop — which is exactly what tripped the makeWrapper/crt1.o failure.
# Same recipe the standalone `openssl` package uses for its native build, so the
# two now share one source of truth (the engine build still has a distinct hash —
# different toolchain — just as engine ncurses differs from the non-engine one).
# autoWire "static": the /etc/ssl retarget is valid on linux-static and darwin
# alike (both honour /etc/ssl); the Windows C:/ssl variant is the mingw overlay's
# job, not native.
{ lib }:
{
  autoWire = "static";
  apply = scope: scope.openssl.overrideAttrs
    (lib.retargetOpenssl "/etc/ssl" "/etc/ssl/engines-3" "/etc/ssl/ossl-modules");
}
