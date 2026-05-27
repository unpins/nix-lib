# mbedtls on mingw, three fixes:
#
# 1. Propagate winpthreads. mbedtls's installed `mbedtls/threading.h`
#    does `#include <pthread.h>` (cmake default
#    `MBEDTLS_THREADING_PTHREAD`), so every consumer needs the
#    include path too — propagated, not buildInputs.
#
# 2. `-DMBEDTLS_FATAL_WARNINGS=OFF`. mbedtls 3.6.x debug logs format
#    `long long` via `%lld`; mingw gcc 14's `-Wformat` flags it as
#    MSVCRT-style, and mbedtls's cmake default promotes warnings to
#    errors.
#
# 3. Append `Libs.private` to all three `.pc` files. Upstream emits
#    only `Libs: -l<name>`, but the static `.a`s reference Windows
#    APIs the consumer's link line wouldn't otherwise pull:
#      - threading.c → `pthread_mutex_*` (winpthreads)
#      - entropy_poll.c → `BCryptGenRandom` (-lbcrypt)
#      - x509_crt.c → `inet_pton` for IP SANs (-lws2_32)
{ lib }:
self: super:
super.mbedtls.overrideAttrs (old: {
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ self.windows.pthreads ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DMBEDTLS_FATAL_WARNINGS=OFF" ];
  postInstall = (old.postInstall or "") + ''
    for pc in $out/lib/pkgconfig/mbedcrypto.pc $out/lib/pkgconfig/mbedtls.pc $out/lib/pkgconfig/mbedx509.pc; do
      [ -f "$pc" ] || continue
      echo 'Libs.private: -lpthread -lbcrypt -lws2_32' >> "$pc"
    done
  '';
})
