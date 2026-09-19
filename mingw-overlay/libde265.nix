# libde265 1.1.1 on mingw: its CMake writes `-lpthread` into the `.pc`'s
# Libs.private whenever find_package(Threads) picks pthreads, but on
# _WIN32 the library threads through Win32 (threads.h) and never calls
# pthreads. The engine's mingw sysroot has no libpthread.a, so every
# `pkg-config --static` consumer (chafa, heif) died on
# `unable to find library -lpthread`. Drop the flag from the `.pc`.
{ lib }:
self: super:
super.libde265.overrideAttrs (oa: {
  postInstall = (oa.postInstall or "") + ''
    for pc in $(find "''${dev:-$out}" "$out" -name libde265.pc 2>/dev/null | sort -u); do
      substituteInPlace "$pc" --replace-fail ' -lpthread' ""
    done
  '';
})
