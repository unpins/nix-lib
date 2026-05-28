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
#    `/nix/store/.../lib{mbedtls,stdc++}.a` paths. ffmpeg's
#    `check_pkg_config` (and any `pkg-config --static` consumer)
#    routes absolute-path args to ldflags — *before* the test
#    object — where `-Wl,--as-needed` drops them (nothing references
#    them yet); then `-lsrt` pulls unresolvable mbedtls / libstdc++
#    (srt is C++) refs. Rewrite both to `-l` form so the cc-wrapper
#    appends them at the tail, after the object. libstdc++ only
#    surfaced on aarch64 — x86_64's libsrt.a happened to need fewer
#    of these C++ symbols — but the `-l` form is correct everywhere.
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
    for pc in $out/lib/pkgconfig/srt.pc $out/lib/pkgconfig/haisrt.pc; do
      [ -f "$pc" ] || continue
      sed -i -E \
        -e 's|[^ ]*/lib(mbed[a-z0-9]+)\.a|-l\1|g' \
        -e 's|[^ ]*/libstdc\+\+\.a|-lstdc++|g' \
        "$pc"
    done
  '';
})
