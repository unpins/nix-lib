# mbedtls on mingw, two fixes:
#
# 1. Default cmake build enables `MBEDTLS_THREADING_C` +
#    `MBEDTLS_THREADING_PTHREAD` which includes `<pthread.h>` from
#    threading.h. mingw's libc doesn't ship pthread.h — it lives in
#    `windows.pthreads` (libwinpthread). Add it to buildInputs so
#    cmake's compiler finds the header.
#
# 2. mbedtls 3.6.x emits `MBEDTLS_PRINTF_LONGLONG` (= `lld`) for the
#    debug-log "client hello, current time" message. mingw's gcc 14
#    still warns on `%lld` for `long long` in `-Wformat` (treats it
#    as MSVCRT printf which wants `%I64d`), even though modern mingw
#    runtimes honor `%lld` via __USE_MINGW_ANSI_STDIO=1. mbedtls
#    forces `-Werror` via `MBEDTLS_FATAL_WARNINGS=ON` by default, so
#    a warning becomes a hard error. Turn the cmake knob off; the
#    code is still warning-clean on every platform we ship except
#    the mingw printf-format-spec false positive.
{ lib }:
self: super:
super.mbedtls.overrideAttrs (old: {
  # `propagatedBuildInputs` (not `buildInputs`): mbedtls's installed
  # headers `#include <pthread.h>` from `mbedtls/threading.h`, so
  # every consumer (librist, libssh, ffmpeg, …) needs the winpthreads
  # include path on its compile line too — not just mbedtls' own build.
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ self.windows.pthreads ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DMBEDTLS_FATAL_WARNINGS=OFF"
  ];
  # mbedtls's three .a libs need windows-side libs that the
  # installed pkgconfig files don't declare:
  #
  # - `libmbedcrypto.a(threading.c.obj)` → `pthread_mutex_*`
  #   (`MBEDTLS_THREADING_PTHREAD` cmake default).
  # - `libmbedcrypto.a(entropy_poll.c.obj)` → `BCryptGenRandom`
  #   (windows CSPRNG, `-lbcrypt`).
  # - `libmbedx509.a(x509_crt.c.obj)` → `inet_pton` for parsing
  #   IP-address SANs in certificates (`-lws2_32`).
  #
  # All three `.pc` files only emit `Libs: -l<name>`, so static
  # consumers (e.g. ffmpeg → librist → mbedcrypto, or ffmpeg's
  # own `--enable-mbedtls` probe via mbedtls.pc) link without
  # these and fail with undef refs. Append the platform libs via
  # `Libs.private`.
  postInstall = (old.postInstall or "") + ''
    for pc in $out/lib/pkgconfig/mbedcrypto.pc $out/lib/pkgconfig/mbedtls.pc $out/lib/pkgconfig/mbedx509.pc; do
      [ -f "$pc" ] || continue
      echo 'Libs.private: -lpthread -lbcrypt -lws2_32' >> "$pc"
    done
  '';
})
