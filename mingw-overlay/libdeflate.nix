# libdeflate on mingw: build the library only.
#
# `programs/` (libdeflate-gzip) enters through `wmain`, so its CMakeLists adds
# `-municode` on MinGW. That flag is what first exposed the engine's mingw CRT
# as ANSI-only: it asks for the UNICODE startup object `crt2u.o`, the link fell
# back to `crt2.o`, whose `mainCRTStartup` wants `main`, and with nothing
# defining it lld pulled `libmingw32.a(crt0_c.o)` — the GUI stub whose `main`
# calls an undefined `WinMain`. The engine builds crt2u.o now, so this is no
# longer a toolchain limit.
#
# The programs stay off anyway, for the ordinary reason: nothing here consumes
# them. libdeflate reaches us as a library, via libtiff. The test programs are
# the same story one directory over — built from `programs/`, and nixpkgs forces
# `-DLIBDEFLATE_BUILD_TESTS=ON` then never runs them (no checkPhase here).
# Filter the ON out rather than append a second flag: cmake takes the last -D,
# but leaving both makes the intent unreadable.
{ lib }:
self: super:
super.libdeflate.overrideAttrs (oa: {
  cmakeFlags =
    builtins.filter
      (f: !(lib.hasPrefix "-DLIBDEFLATE_BUILD_TESTS=" (toString f)))
      (oa.cmakeFlags or [ ])
    ++ [ "-DLIBDEFLATE_BUILD_GZIP=OFF" "-DLIBDEFLATE_BUILD_TESTS=OFF" ];
})
