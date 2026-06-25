# Drop libjpeg-turbo's `simdcoverage` helper (built when WITH_SIMD is on,
# unused by the shipped lib). Its simdcoverage.c references every `jsimd_can_*`
# entry point, but the RVV port added in 3.1.x lacks
# `jsimd_can_encode_mcu_AC_refine_prepare`, so the build aborts on
# -Wimplicit-function-declaration. The RVV SIMD code in libjpeg.a is untouched.
{ lib }:
pkgs:
pkgs.libjpeg.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace simd/CMakeLists.txt \
      --replace-fail "add_executable(simdcoverage simdcoverage.c)" "" \
      --replace-fail "target_link_libraries(simdcoverage jpeg-static)" ""
  '';
})
