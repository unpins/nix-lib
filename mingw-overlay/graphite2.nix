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
# 4. `.pc` rewrite: `Cflags += -DGRAPHITE2_STATIC` (consumer side, pairs with
#    1); plus the C++ runtime, under the name the toolchain actually has.
#
#    This entry carries more than graphite2: `harfbuzz.pc` is `-lharfbuzz -lm`
#    and `Requires: graphite2`, so it is graphite2's runtime name that puts a
#    C++ runtime on the line for everything downstream — including consumers
#    that link with the C driver (pango's tests), which is where dropping it
#    surfaced as undefined `__cxa_*` / `__cxxabiv1` vtables /
#    `__gxx_personality_seh0`.
#
#    `-lstdc++` does not exist under clang/libc++ (harfbuzz's own hb-shape.exe
#    died on `lld: unable to find library -lstdc++`), so on the engine we name
#    the three archives it really ships. A C link resolves them too: the driver
#    builds the C++ runtime and adds its -L when the line NAMES `-lunwind` —
#    the same door rustc goes through, since rustc drives clang, not clang++.
{ lib }:
self: super:
let
  onEngine = lib.hasInfix "unpin-cc" (super.stdenv.cc.name or "");
  cxxRuntime = if onEngine then "-lc++ -lc++abi -lunwind" else "-lstdc++";
in
lib.appendCFlags (super.graphite2.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace CMakeLists.txt \
      --replace-fail "add_subdirectory(tests)" "# add_subdirectory(tests) — dropped for mingw static build"
  '';
  doCheck = false;
  doInstallCheck = false;
  postInstall = (oa.postInstall or "")
    + lib.withPcCflags "-DGRAPHITE2_STATIC"
        "$dev/lib/pkgconfig/graphite2.pc $out/lib/pkgconfig/graphite2.pc"
    + ''
      pc=$dev/lib/pkgconfig/graphite2.pc
      [ -f "$pc" ] || pc=$out/lib/pkgconfig/graphite2.pc
      sed -i 's|-lgraphite2$|-lgraphite2 ${cxxRuntime}|' "$pc"
    '';
})) "-DGRAPHITE2_STATIC"
