# graphite2 cross-mingw, four fixes:
#
# 1. `NIX_CFLAGS += -DGRAPHITE2_STATIC` — headers default `GR2_API` to
#    dllimport; test exes link `libgraphite2.a` and get `__imp_gr_*` undef.
#    See [[mingw-dllimport-static-pattern]].
#
# 2. `postPatch` strips `add_subdirectory(tests)` — its `*_copy_dll`
#    targets copy `libgraphite2.dll`; `BUILD_TESTING=OFF` doesn't gate it.
#
# 3. `doCheck/doInstallCheck = false` — belt-and-braces over (2).
#
# 4. `.pc` rewrite: `Cflags += -DGRAPHITE2_STATIC` (consumer side, pairs
#    with 1); `Libs += -lstdc++` (C++ lib, no DT_NEEDED on static).
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
