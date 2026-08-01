# cJSON on mingw: `isnan`/`isinf` at `cJSON.c:607` expand through mingw's
# `<math.h>` macros into a `-Wfloat-conversion` that gcc 14 + cJSON's
# `-Werror` turns fatal. Mingw runtime-header artifact; just disable the gate.
{ lib }:
self: super:
super.cjson.overrideAttrs (oa: {
  NIX_CFLAGS_COMPILE = (oa.NIX_CFLAGS_COMPILE or "") + " -Wno-error=float-conversion";
})
