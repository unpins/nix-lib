# cJSON on mingw, three fixes:
#
# 1. `isnan`/`isinf` at `cJSON.c:607` expand through mingw's `<math.h>`
#    macros into a `-Wfloat-conversion` that gcc 14 + cJSON's `-Werror`
#    turns fatal. Mingw runtime-header artifact; just disable the gate.
#
# 2. `-fno-stack-protector`. cJSON's cmake turns on -fstack-protector-strong
#    (ENABLE_HARDENING, default ON), and on mingw NOTHING defines
#    `__stack_chk_fail`: mingw-w64 ships no libssp, and nixpkgs itself lists
#    stackprotector as unsupported for this target. gcc hid it by carrying its
#    own libssp; the engine's clang does not. The undefined symbol surfaces at
#    every link that pulls a cJSON object — including the final fold — so the
#    flag has to be off for the library, not just for the tests below.
#
# 3. `-DENABLE_CJSON_TEST=OFF`. The suite links Unity, whose `setUp`/`tearDown`
#    cJSON never defines, and a cross-built test binary cannot run here anyway.
{ lib }:
self: super:
lib.appendCFlags
  (super.cjson.overrideAttrs (oa: {
    cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DENABLE_CJSON_TEST=OFF" ];
  }))
  "-Wno-error=float-conversion -fno-stack-protector"
