# rtmpdump cross-mingw, two fixes:
#
# 1. `SYS=mingw` makeFlag. rtmpdump's Makefile picks SYS via `uname`
#    on the build host (linux → SYS=posix), which omits the
#    `LIBS_mingw` block (`-lws2_32 -lwinmm -lgdi32`). The CLI tools
#    then fail to resolve `gethostbyname` / `send` / `timeGetTime`.
#
# 2. `+ windows.pthreads`. librtmp's threading hooks (handshake.c,
#    rtmp.c) call pthread on every SYS that isn't strictly MSVC.
{ lib }:
self: super:
super.rtmpdump.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "SYS=mingw" ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.windows.pthreads ];
})
