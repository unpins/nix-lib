# nixpkgs `pkgsStatic.rtmpdump`: two issues stacked.
#
# 1. Makefile's `SHARED=yes` default builds `librtmp.so.1`
#    unconditionally; pkgsStatic toolchain can't link `.so`
#    (`crtbeginT.o R_X86_64_32 against __TMC_END__` — static-PIE
#    startup objects refuse to go into a shared object). Override
#    `SHARED=no` so the top-level `all` target reduces to just
#    `librtmp.a`.
#
# 2. Default `CRYPTO=OPENSSL` drags OpenSSL into the closure. Many
#    consumers (ffmpeg, …) prefer to route SSL through a single
#    backend (e.g. mbedtls) at the protocol layer instead of having
#    rtmpdump's per-protocol crypto stack. `CRYPTO=` (empty) maps to
#    `DEF_=-DNO_CRYPTO` in the Makefile, which drops `rtmps://`
#    via librtmp itself. POLARSSL is the only no-OpenSSL alternative
#    librtmp ships, but its API is mbedtls 1.x/2.x — won't compile
#    against modern 3.x without API shims, so cutting the protocol
#    entirely is the cleaner path.
#
# Consumers needing `rtmps://` should provide it through their own
# TLS protocol handler (ffmpeg's `--enable-mbedtls` covers this).
#
# On mingw, rtmpdump's Makefile detects SYS via `uname` on the build
# host (linux → SYS=posix), which omits the Winsock/winmm/gdi32 link
# flags needed for the rtmpdump/rtmpsrv/rtmpsuck/rtmpgw tools to
# resolve `gethostbyname` / `send` / `timeGetTime` etc. Force
# `SYS=mingw` so the Makefile's `LIBS_mingw` block adds the right
# libraries. Also propagate `pkgs.windows.pthreads` because librtmp's
# threading hooks use pthread on every SYS that isn't strictly MSVC.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.rtmpdump.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "SHARED=no" "CRYPTO=" ]
    ++ lib.optionals isMinGW [ "SYS=mingw" ];
  propagatedBuildInputs = [ pkgs.zlib ]
    ++ lib.optionals isMinGW [ pkgs.windows.pthreads ];
})
