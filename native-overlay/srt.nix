# pkgsStatic.srt: swap OpenSSL → mbedtls (`-DUSE_ENCLIB=mbedtls`) so
# consumers carrying `--enable-mbedtls` (ffmpeg) don't pay double
# crypto closure. Four fixes:
#
# 1. `buildInputs`: filter openssl, add mbedtls. Filter rather than
#    replace so platform additions survive (mingw-overlay adds
#    `windows.pthreads`).
#
# 2. `propagatedBuildInputs`: same filter+add. pkgsStatic auto-
#    promotes upstream `buildInputs` into propagated, so openssl
#    survives there too unless we handle both.
#
# 3. cmakeFlags: `-DUSE_ENCLIB=mbedtls -DENABLE_APPS=OFF`. The
#    latter skips srt-live-transmit/srt-file-transmit/srt-tunnel
#    CLI binaries that ffmpeg doesn't consume.
#
# 4. `srt.pc Libs.private` sed: srt's CMake bakes absolute
#    `/nix/store/.../libmbedtls.a` paths. With `pkg-config --static`
#    they land *before* the test object, `-Wl,--as-needed` drops
#    them, then `-lsrt` later introduces unresolvable mbedtls refs.
#    Sed to `-l` form so cc-wrapper appends `-L<store>/lib -lmbed*`
#    at the tail.
{ lib }:
pkgs:
let
  dropOpenssl = builtins.filter (d: (d.pname or "") != "openssl");
in
pkgs.srt.overrideAttrs (oa: {
  buildInputs = dropOpenssl (oa.buildInputs or [ ]) ++ [ pkgs.mbedtls ];
  propagatedBuildInputs = dropOpenssl (oa.propagatedBuildInputs or [ ]) ++ [ pkgs.mbedtls ];
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DUSE_ENCLIB=mbedtls"
    "-DENABLE_APPS=OFF"
  ];
  postInstall = (oa.postInstall or "") + ''
    sed -i -E 's|[^ ]*/lib(mbed[a-z0-9]+)\.a|-l\1|g' \
      $out/lib/pkgconfig/srt.pc
  '';
})
