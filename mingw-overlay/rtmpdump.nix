# rtmpdump cross-mingw, two fixes:
#
# 1. `SYS=mingw`. The Makefile picks SYS via build-host `uname`
#    (linux → posix), dropping the `LIBS_mingw` block
#    (`-lws2_32 -lwinmm -lgdi32`) so `gethostbyname`/`send`/
#    `timeGetTime` go unresolved.
#
# 2. `+ windows.pthreads`. librtmp calls pthread on every non-MSVC SYS.
{ lib }:
self: super:
super.rtmpdump.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "SYS=mingw" ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.windows.pthreads ];
})
