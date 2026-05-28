# pkgsStatic.libssh: swap OpenSSL → mbedtls (`-DWITH_MBEDTLS=ON`).
# Why mbedtls not OpenSSL: see docs/crypto-backend.md. Four fixes:
#
# 1. `buildInputs`: drop openssl, install [zlib, mbedtls, libsodium].
#
# 2. `propagatedBuildInputs`: same list. pkgsStatic auto-promotes
#    upstream buildInputs into propagated, so swapping on
#    buildInputs alone leaves openssl in the closure.
#
# 3. cmakeFlags: `-DWITH_MBEDTLS=ON` switches libssh's crypto
#    backend from OpenSSL to mbedtls.
#
# 4. postFixup: append `Requires.private: mbedtls libsodium zlib`
#    to libssh.pc. `libssh.pc.cmake` leaves Requires.private empty
#    for the crypto backend, so static consumers fail with
#    `mbedtls_*` undef. Append rather than sed-replace — CMake
#    drops the line entirely when its variable is empty.
#    postFixup (not postInstall) because multipleOutputsPhase
#    moves the `.pc` to $dev after install.
{ lib }:
pkgs:
let
  cryptoChain = [ pkgs.zlib pkgs.mbedtls pkgs.libsodium ];
in
pkgs.libssh.overrideAttrs (oa: {
  buildInputs = cryptoChain;
  propagatedBuildInputs = cryptoChain;
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_MBEDTLS=ON" ];
  postFixup = (oa.postFixup or "") + ''
    echo 'Requires.private: mbedtls libsodium zlib' \
      >> $dev/lib/pkgconfig/libssh.pc
  '';
})
