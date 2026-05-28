# libjpeg-turbo's `simd/CMakeLists.txt` builds a `simdcoverage` helper
# whenever WITH_SIMD is on. Its `simdcoverage.c` references the full set of
# `jsimd_can_*` entry points, but not every arch's jsimd port declares all
# of them — the RISC-V Vector (RVV) port added in 3.1.x is missing
# `jsimd_can_encode_mcu_AC_refine_prepare`, so the build aborts with
# -Wimplicit-function-declaration. The helper is a SIMD-dispatch coverage
# artifact, unused by the shipped library, so drop the target. The RVV SIMD
# code in libjpeg.a itself is untouched.
{ lib }:
pkgs:
pkgs.libjpeg.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace simd/CMakeLists.txt \
      --replace-fail "add_executable(simdcoverage simdcoverage.c)" "" \
      --replace-fail "target_link_libraries(simdcoverage jpeg-static)" ""
  '';
})
