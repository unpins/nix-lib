# pkgsStatic.librist, two fixes:
#
# 1. `-Dtest=false -Dbuilt_tools=false`. The cmocka test sources redefine
#    `free` as `_test_free(...)`, colliding with musl's `__attribute_malloc__`
#    on `free` so they fail to compile. The CLI tools are dead weight for a
#    `librist.a` consumer.
#
# 2. `propagatedBuildInputs += cjson + mbedtls`. librist.pc declares
#    `Requires: mbedcrypto, libcjson` (public); nixpkgs keeps both only in
#    buildInputs, so consumer `pkg-config librist`'s Requires traversal can't
#    locate libcjson.pc and ffmpeg reports `librist >= 0.2.7 not found`.
{ lib }:
pkgs:
pkgs.librist.overrideAttrs (oa: {
  mesonFlags = (oa.mesonFlags or [ ]) ++ [
    "-Dtest=false"
    "-Dbuilt_tools=false"
  ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [
    pkgs.cjson
    pkgs.mbedtls
  ];
})
