# pkgsStatic.libssh: swap OpenSSL → mbedtls. Why mbedtls: see
# docs/crypto-backend.md. Four fixes:
#
# 1. `buildInputs`: drop openssl, install [zlib, mbedtls, libsodium].
#
# 2. `propagatedBuildInputs`: same list — pkgsStatic auto-promotes upstream
#    buildInputs, so swapping buildInputs alone leaves openssl in the closure.
#
# 3. cmakeFlags: `-DWITH_MBEDTLS=ON` selects the mbedtls crypto backend.
#
# 4. postFixup: append `Requires.private: mbedtls libsodium zlib` to libssh.pc
#    (libssh.pc.cmake leaves it empty for the backend, so static consumers
#    fail with `mbedtls_*` undef). Append, not sed — CMake drops the line when
#    the variable is empty. postFixup not postInstall because
#    multipleOutputsPhase moves the `.pc` to $dev after install.
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
