# pkgsStatic.rtmpdump, two fixes:
#
# 1. `SHARED=no`. Makefile's default builds `librtmp.so.1`
#    unconditionally; pkgsStatic toolchain can't link `.so`
#    (`crtbeginT.o R_X86_64_32 against __TMC_END__` — static-PIE
#    startup objects refuse to go into a shared object). `SHARED=no`
#    reduces the top-level `all` to `librtmp.a` + CLI tools.
#
# 2. `CRYPTO=` (empty). Default `CRYPTO=OPENSSL` drags OpenSSL into
#    the closure. `CRYPTO=` maps to `DEF_=-DNO_CRYPTO`, dropping
#    `rtmps://` from librtmp itself. Consumers needing rtmps://
#    should route TLS through their own protocol handler (ffmpeg's
#    `--enable-mbedtls` covers it). POLARSSL — the only no-OpenSSL
#    alternative librtmp ships — is mbedtls 1.x/2.x API, won't
#    compile against modern 3.x without shims.
#
# Plus zlib propagation (librtmp.pc emits `-lz` for AMF / SWF
# verification helpers).
{ lib }:
pkgs:
pkgs.rtmpdump.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "SHARED=no" "CRYPTO=" ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ pkgs.zlib ];
})
