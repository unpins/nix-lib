# pkgsStatic.libyuv: drop the SHARED library target — the `yuv_shared`
# `.so` link dies under musl-static with `crtbeginT.o R_X86_64_32 against
# __TMC_END__` (no PIC unwinder CRT for a `.so`). Consumers link the static
# `.a`, so delete every line mentioning `ly_lib_shared`.
#
# UNIT_TEST=OFF (nixpkgs sets it ON): drags gtest + 3454 tests, pointless
# for a transitive codec dep.
#
# libyuv-sve2-uv-tail.patch: heap overflow in the SVE2 RGB->UV tail when the
# vector is wider than 128 bits (see the patch).
{ lib }:
pkgs:
pkgs.libyuv.overrideAttrs (oa: {
  cmakeFlags = [ "-DUNIT_TEST=OFF" ];
  doCheck = false;
  patches = (oa.patches or [ ]) ++ [ ./libyuv-sve2-uv-tail.patch ];
  postPatch = (oa.postPatch or "") + ''
    sed -i '/ly_lib_shared/d' CMakeLists.txt
  '';
})
