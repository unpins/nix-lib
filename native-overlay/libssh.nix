# pkgsStatic.libssh for ffmpeg, on OpenSSL — the TLS library ffmpeg itself
# links (see docs/crypto-backend.md), so the SSH crypto adds nothing. Three
# fixes:
#
# 1. `-DWITH_NACL=OFF` and no libsodium. nixpkgs passes libsodium, and libssh
#    links it whenever it is found, but OpenSSL already provides curve25519 and
#    ed25519: it would be a second crypto library for nothing.
#
# 2. `propagatedBuildInputs` = [zlib, openssl] — pkgsStatic auto-promotes
#    upstream buildInputs, so setting buildInputs alone would keep libsodium in
#    the closure.
#
# 3. postFixup: append `Requires.private: libcrypto zlib` to libssh.pc
#    (libssh.pc.cmake leaves it empty for the backend, so static consumers
#    fail with undefined crypto symbols). Append, not sed — CMake drops the
#    line when the variable is empty. postFixup not postInstall because
#    multipleOutputsPhase moves the `.pc` to $dev after install.
{ lib }:
pkgs:
let
  cryptoChain = [ pkgs.zlib pkgs.openssl ];
in
pkgs.libssh.overrideAttrs (oa: {
  buildInputs = cryptoChain;
  propagatedBuildInputs = cryptoChain;
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_NACL=OFF" ];
  postFixup = (oa.postFixup or "") + ''
    echo 'Requires.private: libcrypto zlib' \
      >> $dev/lib/pkgconfig/libssh.pc
  '';
})
