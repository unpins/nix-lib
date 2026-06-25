# srt cross-mingw, two fixes:
#
# 1. `+ windows.pthreads`. CMake `find_package(Threads REQUIRED)`
#    needs winpthreads on mingw.
#
# 2. `srt.pc`/`haisrt.pc` `Libs.private` sed-strip. CMake's probe
#    captures the dynamic C++ EH sequence (`-lgcc_s` ×2); static
#    consumers re-inject it and the `.exe` imports
#    `libgcc_s_seh-1.dll`. `-static-libgcc` at final link suffices.
#    See [[mingw-pc-libgcc-s-probe-trap]].
{ lib }:
self: super:
super.srt.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ]) ++ [ self.windows.pthreads ];
  postInstall = (oa.postInstall or "") + ''
    for pc in $out/lib/pkgconfig/srt.pc $out/lib/pkgconfig/haisrt.pc; do
      [ -f "$pc" ] || continue
      sed -i -E 's| -lmingw32 -lgcc_s -lgcc -lmingwex -lkernel32 -lmcfgthread -lkernel32 -lntdll -ladvapi32 -lshell32 -luser32 -lkernel32 -lmingw32 -lgcc_s -lgcc -lmingwex -lkernel32 -lmcfgthread -lkernel32 -lntdll||g' \
        "$pc"
    done
  '';
})
