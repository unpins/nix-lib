# zlib on mingw builds via `win32/Makefile.gcc`, whose `all`/`install`
# targets ALWAYS build `zlib1.dll` (`SHARED_MODE` only gates whether install
# copies it). Two problems: the unpin-llvm mingw CRT has no DLL startup object
# so the DLL link fails (`undefined symbol: DllMainCRTStartup`), and every
# unpins windows binary is `-all-static` against `libz.a` anyway.
#
# Restrict both targets to `$(STATICLIB)`. The install body already guards the
# DLL/implib copy behind `SHARED_MODE=1` (off here), so only the `all` target
# and the `install` prerequisite need trimming.
{ lib }:
self: super:
super.zlib.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    sed -i \
      -e 's/^all: .*/all: $(STATICLIB)/' \
      -e '/^install:/ s/ $(IMPLIB)//' \
      win32/Makefile.gcc
  '';
})
