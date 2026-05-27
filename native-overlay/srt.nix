# nixpkgs `pkgsStatic.srt` defaults to OpenSSL crypto. Consumers
# that already carry `mbedtls` (e.g. ffmpeg's `--enable-mbedtls`)
# pay double for crypto closure when srt drags OpenSSL in alongside.
# Swap to mbedtls: srt's CMake supports `-DUSE_ENCLIB=mbedtls` and
# ships `scripts/FindMbedTLS.cmake`, which discovers the static
# mbedtls via `CMAKE_PREFIX_PATH`.
#
# Three details to get right:
#
# 1. `buildInputs` rewritten from scratch (no openssl). mingw also
#    needs `windows.pthreads`.
#
# 2. `propagatedBuildInputs` REPLACED, not extended. pkgsStatic
#    auto-promotes the upstream `buildInputs` (which includes
#    openssl) into `propagatedBuildInputs` at scope creation; if we
#    only extend, openssl stays in the closure.
#
# 3. srt's CMake bakes absolute `/nix/store/.../libmbedtls.a` paths
#    into `Libs.private` of `srt.pc`. Consumers using
#    `pkg-config --static` put those absolute paths *before* the
#    test object on the link command, and `-Wl,--as-needed` drops
#    them (no unresolved refs yet); then `-lsrt` (after test.o)
#    introduces mbedtls refs that nothing remains to resolve.
#    Rewrite to `-l` form via a sed so the cc-wrapper appends
#    `-L${mbedtls}/lib -lmbedtls…` at the tail of the link line.
#
# 4. mingw-only: srt's CMake (same probe as x265) also embeds the
#    captured C++ EH link sequence in `Libs.private`, including
#    `-lgcc_s` twice. Static consumers (`pkg-config --static`) then
#    re-inject `-lgcc_s`, the linker picks `libgcc_s.dll.a` (an
#    import lib for `libgcc_s_seh-1.dll`), and the .exe ends up
#    importing the DLL even with `-static -static-libgcc`. Sed away
#    the `-lmingw32 -lgcc_s -lgcc -lmingwex … -lntdll` blocks —
#    they're spec-provided at the final link anyway (gcc's link
#    sequence with `-static-libgcc` yields the static form).
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.srt.overrideAttrs (oa: {
  buildInputs = [ pkgs.mbedtls ]
    ++ pkgs.lib.optionals isMinGW [
      pkgs.windows.pthreads
    ];
  propagatedBuildInputs = [ pkgs.mbedtls ];
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DUSE_ENCLIB=mbedtls"
    "-DENABLE_APPS=OFF"
  ];
  postInstall = (oa.postInstall or "") + ''
    sed -i -E 's|[^ ]*/lib(mbed[a-z0-9]+)\.a|-l\1|g' \
      $out/lib/pkgconfig/srt.pc
  '' + lib.optionalString isMinGW ''
    for pc in $out/lib/pkgconfig/srt.pc $out/lib/pkgconfig/haisrt.pc; do
      [ -f "$pc" ] || continue
      sed -i -E 's| -lmingw32 -lgcc_s -lgcc -lmingwex -lkernel32 -lmcfgthread -lkernel32 -lntdll -ladvapi32 -lshell32 -luser32 -lkernel32 -lmingw32 -lgcc_s -lgcc -lmingwex -lkernel32 -lmcfgthread -lkernel32 -lntdll||g' \
        "$pc"
    done
  '';
})
