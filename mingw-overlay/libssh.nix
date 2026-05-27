# libssh cross-mingw, one fix:
#
# `libssh.pc` rewrite: `Cflags += -DLIBSSH_STATIC` (headers default
# to dllimport on _WIN32 — see [[mingw-dllimport-static-pattern]]),
# `Libs += -lws2_32 -liphlpapi` (connector.c calls Winsock2 APIs,
# misc.c calls if_nametoindex from IPHLPAPI — see
# [[mingw-libs-private-winapis]]).
{ lib }:
self: super:
super.libssh.overrideAttrs (oa: {
  postFixup = (oa.postFixup or "") + ''
    sed -i \
      -e 's|^Cflags: |Cflags: -DLIBSSH_STATIC |' \
      -e 's|^Libs: \(.*\)$|Libs: \1 -lws2_32 -liphlpapi|' \
      $dev/lib/pkgconfig/libssh.pc
  '';
})
