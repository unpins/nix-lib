# nixpkgs `pkgsStatic.libssh` defaults to OpenSSL via
# `find_package(OpenSSL)`. Same motivation as [[srt]]: consumers
# already carrying mbedtls (e.g. ffmpeg's `--enable-mbedtls`) avoid
# double crypto by swapping libssh's backend too. libssh's CMake
# supports `-DWITH_MBEDTLS=ON` and ships its own `FindMbedTLS.cmake`.
#
# Three details:
#
# 1. `buildInputs` rewritten from scratch (no openssl).
# 2. `propagatedBuildInputs` REPLACED, not extended (pkgsStatic
#    auto-promotes upstream buildInputs into it; only replacement
#    drops openssl from the closure).
# 3. libssh's `libssh.pc.cmake` leaves `Requires.private` empty for
#    the crypto backend (CMakeLists only appends gssapi to
#    `LIBSSH_PC_REQUIRES_PRIVATE`). Consumers using `pkg-config
#    --static` get no transitive crypto link flags — link probe fails
#    with `mbedtls_*` undefined. Inject `Requires.private` so
#    pkg-config resolves `mbedtls.pc` / `libsodium.pc` / `zlib.pc`
#    and emits the missing `-L/-l`.
#
# `postFixup` (not `postInstall`) — multipleOutputsPhase moves the
# `.pc` to `$dev` after install runs; sed needs to wait. Append
# rather than replace (CMake drops the `Requires.private` line
# entirely when `LIBSSH_PC_REQUIRES_PRIVATE` is empty).
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.libssh.overrideAttrs (oa: {
  buildInputs = [
    pkgs.zlib
    pkgs.mbedtls
    pkgs.libsodium
  ];
  propagatedBuildInputs = [
    pkgs.zlib
    pkgs.mbedtls
    pkgs.libsodium
  ];
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DWITH_MBEDTLS=ON" ];
  postFixup = (oa.postFixup or "") + ''
    echo 'Requires.private: mbedtls libsodium zlib' \
      >> $dev/lib/pkgconfig/libssh.pc
  '' + lib.optionalString isMinGW ''
    # libssh.h decorates the public API with __declspec(dllimport)
    # on _WIN32 unless LIBSSH_STATIC is defined (libssh.h:27-40).
    # Static consumers linking libssh.a then see __imp_ssh_* /
    # __imp_sftp_* refs that the static archive can't satisfy.
    # Inject -DLIBSSH_STATIC into the .pc Cflags.
    #
    # libssh.a's `connect.c`/`connector.c` call Windows Winsock2
    # APIs (`closesocket`, `recv`, `send`, `WSAGetLastError`,
    # `__WSAFDIsSet`, `WspiapiFreeAddrInfo`, `gai_strerrorA`),
    # and `misc.c` calls `if_nametoindex`. These live in
    # `ws2_32.dll` and `iphlpapi.dll` respectively (import libs
    # `libws2_32.a` + `libiphlpapi.a`). The `Wspiapi*` aliases are
    # header-only in `wspiapi.h` and resolve statically. Upstream
    # libssh.pc.cmake never appends the platform libs because the
    # cmake variable goes into `LIBSSH_LINK_LIBRARIES` used only
    # for the shared build. Append both so the static probe link
    # line picks them up.
    sed -i \
      -e 's|^Cflags: |Cflags: -DLIBSSH_STATIC |' \
      -e 's|^Libs: \(.*\)$|Libs: \1 -lws2_32 -liphlpapi|' \
      $dev/lib/pkgconfig/libssh.pc
  '';
})
