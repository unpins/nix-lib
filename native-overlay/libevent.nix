# Inject the pkg-config that nixpkgs' libevent forgets. Invisible on
# x86_64/aarch64 (the bare `cc -lssl -lcrypto` probe resolves), but on armv7l
# OpenSSL 3.x's libcrypto.a needs libatomic's `__atomic_*_8` — declared only
# in libcrypto.pc's Libs.private, which the bare probe misses (undefined
# `__atomic_fetch_add_8`). Pass `scope.pkg-config` (splicing-aware) so the
# cross-correct `<triple>-pkg-config-wrapper` is picked.
{ lib }:
scope:
scope.libevent.overrideAttrs (oa: {
  nativeBuildInputs = (oa.nativeBuildInputs or [ ]) ++ [ scope.pkg-config ];
})
