# pkgsStatic.srt: swap OpenSSL → mbedtls (rationale: docs/crypto-backend.md).
# Four fixes:
#
# 1. `buildInputs`: filter openssl, add mbedtls. Filter (not replace) so
#    platform additions survive (mingw-overlay adds `windows.pthreads`).
#
# 2. `propagatedBuildInputs`: same — pkgsStatic auto-promotes `buildInputs`
#    into propagated, so openssl survives there too.
#
# 3. cmakeFlags: `-DENABLE_APPS=OFF` skips CLI binaries ffmpeg doesn't use.
#
# 4. `Libs.private` sed: CMake bakes absolute `lib{mbedtls,stdc++}.a` paths;
#    `pkg-config --static` consumers route absolute args to ldflags *before*
#    the test object where `--as-needed` drops them → unresolvable refs.
#    Rewrite to `-l` form so cc-wrapper appends at the tail. (libstdc++ only
#    surfaced on aarch64, but `-l` is correct everywhere.)
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
