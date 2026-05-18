# Inject pkg-config into libevent's nativeBuildInputs. nixpkgs' libevent
# forgets it, which is invisible on x86_64/aarch64 because the configure
# fallback probe `cc conftest.c -lssl -lcrypto` resolves on its own. On
# armv7l (ARM 32-bit) OpenSSL 3.x's libcrypto.a needs `__atomic_*_8`
# from libatomic — `libcrypto.pc` declares it in `Libs.private`, but only
# `pkg-config --libs --static openssl` surfaces it; the bare probe fails
# the link with undefined `__atomic_fetch_add_8`. Splicing-aware: pass
# `scope.pkg-config` (not `scope.buildPackages.pkg-config`) so nixpkgs
# picks the cross-correct `<triple>-pkg-config-wrapper`.
{ lib }:
scope:
scope.libevent.overrideAttrs (oa: {
  nativeBuildInputs = (oa.nativeBuildInputs or [ ]) ++ [ scope.pkg-config ];
})
