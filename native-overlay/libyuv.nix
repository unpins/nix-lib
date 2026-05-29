# pkgsStatic.libyuv: drop the SHARED library target.
#
# libyuv's CMakeLists builds both `yuv` (STATIC) and `yuv_shared` (SHARED)
# from the same objects. Under pkgsStatic the shared link dies:
#   crtbeginT.o: relocation R_X86_64_32 against hidden symbol `__TMC_END__'
#   can not be used when making a shared object
# crtbeginT.o is the static-only CRT; a musl-static toolchain has no PIC
# unwinder CRT to satisfy a `.so`. Consumers (libavif → chafa, ImageMagick)
# link the static `libyuv.a`, so the shared target is dead weight. The var
# `ly_lib_shared` is defined once and referenced only by the shared target's
# add_library/set_target_properties/install lines — delete every line that
# mentions it. The `find_package(JPEG)` block keeps its include dirs and
# -DHAVE_JPEG, which still decorate the static lib.
#
# Also force UNIT_TEST=OFF (nixpkgs sets it ON): it drags gtest and runs
# 3454 tests, pointless for a transitive codec dep.
{ lib }:
pkgs:
pkgs.libyuv.overrideAttrs (oa: {
  cmakeFlags = [ "-DUNIT_TEST=OFF" ];
  doCheck = false;
  postPatch = (oa.postPatch or "") + ''
    sed -i '/ly_lib_shared/d' CMakeLists.txt
  '';
})
