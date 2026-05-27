# cJSON on mingw: `cJSON.c:607` does `if (isnan(d) || isinf(d))`,
# which expands through mingw's `<math.h>` macro into something
# gcc 14 flags as `-Wfloat-conversion` (`double → float may change
# value`). cJSON's CMake sets `-Werror` so the warning aborts the
# build. Disable the float-conversion gate on mingw; the macro
# itself is fine, this is a mingw runtime-header artifact.
{ lib }:
self: super:
super.cjson.overrideAttrs (old: {
  NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -Wno-error=float-conversion";
})
