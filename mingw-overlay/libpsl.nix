# libpsl:
# - Default .pc puts libidn2/libunistring/libiconv in Libs.private. Curl's
#   pkg-config probe uses --libs-only-l which only honors Libs:. Promote them,
#   ordered consumer-before-provider for single-pass static linking.
# - Propagate libunistring/libiconv so strictDeps consumers get -L paths.
# - `.override { libidn2 = ... }` re-threads the overlay'd libidn2 (overrideAttrs
#   alone doesn't re-evaluate the call's args).
{ lib }:
self: super:
(super.libpsl.override {
  inherit (self) libidn2;
}).overrideAttrs (old: {
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ])
    ++ [ self.libunistring self.libiconv ];
  postFixup = (old.postFixup or "") + ''
    pc="$dev/lib/pkgconfig/libpsl.pc"
    if [ -f "$pc" ]; then
      sed -i '/^Libs:/c\
Libs: -L''${libdir} -L${self.libunistring}/lib -L${self.libiconv}/lib -lpsl -lidn2 -lunistring -liconv -lws2_32
' "$pc"
    fi
  '';
})
