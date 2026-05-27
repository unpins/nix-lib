# pkgsStatic.librist, two fixes:
#
# 1. `-Dtest=false -Dbuilt_tools=false`. The cmocka-based test
#    sources (`srp_examples.c`, `srp_unit.c`) redefine `free` as
#    `_test_free(...)` via a header pragma; cmocka 1.x + musl's
#    `__attribute_malloc__` decoration on `free` collide and the
#    test sources fail to compile. The CLI tools (ristsender /
#    ristreceiver) are dead weight for a consumer linking against
#    `librist.a`.
#
# 2. `propagatedBuildInputs += cjson + mbedtls`. `librist.pc`
#    declares `Requires: mbedcrypto, libcjson` (public, not
#    `.private`). nixpkgs keeps both in `buildInputs`, so consumer
#    `pkg-config librist` finds librist.pc but the `Requires:`
#    traversal fails to locate `libcjson.pc` — ffmpeg's version
#    probe then reports `librist >= 0.2.7 not found`.
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
