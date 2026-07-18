# Drop libjpeg-turbo's `simdcoverage` helper (built when WITH_SIMD is on,
# unused by the shipped lib). Its simdcoverage.c references every `jsimd_can_*`
# entry point, but the RVV port added in 3.1.x lacks
# `jsimd_can_encode_mcu_AC_refine_prepare`, so the build aborts on
# -Wimplicit-function-declaration. The RVV SIMD code in libjpeg.a is untouched.
# (This part is opt-in per-flake, gated riscv via nativeFixes."libjpeg-turbo".)
#
# lto=false — SEPARATE, SET-WIDE fix (wired in mkStandaloneFlake's
# enginePkgsStaticFor, `withLibjpegNoLto`, NOT here): the engine's full -flto
# MISCOMPILES libjpeg-turbo. CTest #121 bmpsizetest hangs → OOM (~60s SIGKILL):
# its 65500x65500 whole-image path allocates ~12GB instead of streaming, a
# codegen fault the LTO whole-program pass introduces. A/B (same clang 21.1.8,
# same 3.1.4 source): lto=false → PASS 0.01s (= stock gcc), lto=full → hang,
# lto=thin → lld SEGFAULT. So no-LTO is the only clean build; the shared libjpeg
# is built with it so every codec consumer (aom/avif/heif/jxl/chafa/ffmpeg/
# jpeg-tools/openjpeg/jbig2/poppler…) is correct. The swap lives in
# enginePkgsStaticFor because the lto=false engine stdenv needs the BASE pkgs the
# adapter wraps, which an autoWire `apply` (post-swap set only) can't supply.
{ lib }:
pkgs:
pkgs.libjpeg.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace simd/CMakeLists.txt \
      --replace-fail "add_executable(simdcoverage simdcoverage.c)" "" \
      --replace-fail "target_link_libraries(simdcoverage jpeg-static)" ""
  '';
})
