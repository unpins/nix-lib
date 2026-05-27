# graphite2 cross-mingw, four fixes:
#
# 1. `NIX_CFLAGS += -DGRAPHITE2_STATIC` (own build). Public
#    headers default `GR2_API` to `__declspec(dllimport)` unless
#    this macro is defined. The test executables
#    (`featuremaptest`, …) link against `libgraphite2.a` and fail
#    with `__imp_gr_*` undef. See
#    [[mingw-dllimport-static-pattern]].
#
# 2. `postPatch` strips `add_subdirectory(tests)` from
#    `CMakeLists.txt`. The `tests/CMakeLists.txt` declares
#    `*_copy_dll` targets that copy `libgraphite2.dll` into test
#    dirs; `BUILD_TESTING=OFF` doesn't gate
#    `add_subdirectory(tests)` at top level.
#
# 3. `doCheck = false; doInstallCheck = false`. Belt-and-braces
#    on top of (2) so nixpkgs' default check phase doesn't try
#    to run the (now-absent) test binaries.
#
# 4. `.pc` rewrite: `Cflags += -DGRAPHITE2_STATIC` (consumer
#    side — pairs with fix 1); `Libs: -lgraphite2 -lstdc++`
#    (graphite2 is C++, static consumers don't pull libstdc++
#    via DT_NEEDED).
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
  postInstall = (old.postInstall or "") + ''
    pc=$dev/lib/pkgconfig/graphite2.pc
    [ -f "$pc" ] || pc=$out/lib/pkgconfig/graphite2.pc
    sed -i 's|^Cflags: |Cflags: -DGRAPHITE2_STATIC |' "$pc"
    sed -i 's|-lgraphite2$|-lgraphite2 -lstdc++|' "$pc"
  '';
})
