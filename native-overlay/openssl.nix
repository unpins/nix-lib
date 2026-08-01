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
  apply = pkgs:
    let
      base = pkgs.openssl.overrideAttrs
        (lib.retargetOpenssl "/etc/ssl" "/etc/ssl/engines-3" "/etc/ssl/ossl-modules");
      # 32-bit ARM (armv7l/armv6): OpenSSL's Configure appends `-latomic` to its
      # own app/test link (apps/openssl etc.). A static-musl + compiler-rt
      # toolchain ships no `libatomic.a` — the generic `__atomic_*` libcalls live
      # in `libclang_rt.builtins.a` (engine builtins now include atomic.c) — so
      # the bare `-latomic` fails with "unable to find library -latomic". Provide
      # an EMPTY libatomic.a so the flag resolves; the real symbols still come
      # from builtins (pulled via the driver's end-group). An empty ar archive is
      # the arch-independent 8-byte `!<arch>\n`, so one stub serves any target.
      # 64-bit targets never emit `-latomic`, hence the isAarch32 gate — the drv
      # (and byte-identical output) of every other arch is untouched.
      libatomicStub = pkgs.runCommand "libatomic-stub" { } ''
        mkdir -p "$out/lib"
        printf '!<arch>\n' > "$out/lib/libatomic.a"
      '';
      addStubL = o:
        if o ? env && o.env ? NIX_LDFLAGS then {
          env = o.env // { NIX_LDFLAGS = o.env.NIX_LDFLAGS + " -L${libatomicStub}/lib"; };
        } else {
          NIX_LDFLAGS = (o.NIX_LDFLAGS or "") + " -L${libatomicStub}/lib";
        };
      # …and the same `-latomic` rides along in the installed `libcrypto.pc` /
      # `libssl.pc` `Libs.private` (OpenSSL's Configure `ex_libs`). CONSUMERS that
      # link static openssl via `pkg-config --static` (kmod's PKG_CHECK_MODULES,
      # curl, …) inherit that flag on their OWN link line, where the openssl-drv
      # stub above doesn't reach — so each would need its own stub. Strip
      # `-latomic` from the .pc instead: the `__atomic_*` libcalls resolve from
      # every engine consumer's compiler-rt builtins (a6a3473 folded atomic.c in),
      # so the flag is pure dead weight everywhere. One fix, every consumer clean.
      stripPcAtomic = o: {
        postInstall = (o.postInstall or "") + ''
          for pc in "''${dev:-$out}"/lib/pkgconfig/*.pc "$out"/lib/pkgconfig/*.pc; do
            [ -e "$pc" ] && sed -i 's/ -latomic\b//g' "$pc"
          done
          true
        '';
      };
    in
    if pkgs.stdenv.hostPlatform.isAarch32
    then base.overrideAttrs (o: (addStubL o) // (stripPcAtomic o))
    else base;
}
