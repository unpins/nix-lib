# graphite2 on mingw: its public headers (`graphite2/Types.h`)
# default `GR2_API` to `__declspec(dllimport)` unless
# `GRAPHITE2_STATIC` is defined. The test executables
# (`featuremaptest`, …) link against the static `libgraphite2.a`
# but still see the DLL-import decorations and fail with
# `undefined reference to __imp_gr_*`.
#
# Additionally, `tests/CMakeLists.txt` declares `*_copy_dll`
# targets that copy `libgraphite2.dll` into the test
# directories. These targets run during the build and fail
# in a static build because the DLL doesn't exist. The top-
# level `CMakeLists.txt` calls `add_subdirectory(tests)`
# unconditionally — `BUILD_TESTING=OFF` doesn't gate it — so
# strip the line entirely via postPatch.
{ lib }:
self: super:
super.graphite2.overrideAttrs (old: {
  NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -DGRAPHITE2_STATIC";
  postPatch = (old.postPatch or "") + ''
    substituteInPlace CMakeLists.txt \
      --replace-fail "add_subdirectory(tests)" "# add_subdirectory(tests) — dropped for mingw static build"
  '';
  doCheck = false;
  doInstallCheck = false;
  # graphite2's public headers default `GR2_API` to
  # `__declspec(dllimport)`. Consumers (harfbuzz, …) linking
  # against the static `libgraphite2.a` get `__imp_gr_*`
  # undefined references unless they compile with
  # `-DGRAPHITE2_STATIC`. Inject it into `Cflags:` of the .pc
  # so every pkg-config consumer picks it up automatically.
  postInstall = (old.postInstall or "") + ''
    pc=$dev/lib/pkgconfig/graphite2.pc
    [ -f "$pc" ] || pc=$out/lib/pkgconfig/graphite2.pc
    sed -i 's|^Cflags: |Cflags: -DGRAPHITE2_STATIC |' "$pc"
    # graphite2 is C++. When consumers (harfbuzz, pango, …)
    # statically link `libgraphite2.a`, ld needs the C++ runtime
    # (`__gxx_personality_seh0`, RTTI vtables, `__cxa_*`).
    # On dynamic builds `.so` brings its own DT_NEEDED for
    # libstdc++; on static mingw the linker drops `-lstdc++`
    # entirely unless the consumer asks for it. Append it to
    # `Libs:` so every pkg-config consumer picks it up.
    sed -i 's|-lgraphite2$|-lgraphite2 -lstdc++|' "$pc"
  '';
})
