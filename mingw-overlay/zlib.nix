# zlib on mingw builds via its hand-written `win32/Makefile.gcc`, whose `all`
# and `install` targets ALWAYS build the shared `zlib1.dll` (+ import lib) —
# the `SHARED_MODE` flag only gates whether install *copies* them, not whether
# they're built. Two problems for unpins:
#
#   * The unpin-llvm engine's mingw CRT (VFS-synthesized) has the EXE startup
#     but no DLL startup object, so linking `zlib1.dll` fails with
#     `undefined symbol: DllMainCRTStartup` / `WinMain`.
#   * Every unpins windows binary is `-all-static` and links `libz.a`; the DLL
#     is pure collateral.
#
# Restrict both targets to the static `$(STATICLIB)` (libz.a). The install
# body already guards the DLL/implib copy behind `SHARED_MODE=1` (off under
# mingwStaticCross's isStatic), so only the `all` target and the `install`
# prerequisite need trimming. Static-only zlib is correct for the whole
# windows catalog (gcc cross builds it too, just wastes work on the DLL).
{ lib }:
self: super:
super.zlib.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    sed -i \
      -e 's/^all: .*/all: $(STATICLIB)/' \
      -e '/^install:/ s/ $(IMPLIB)//' \
      win32/Makefile.gcc
  '';
})
