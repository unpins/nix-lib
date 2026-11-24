# harfbuzz linked into freetype, statically: without it at build time,
# configure's `auto` falls back to LoadLibrary("libharfbuzz-0.dll") in the
# autohinter, which loads whatever DLL of that name is on the search path.
# Bootstrapped as in ../native-overlay/freetype.nix; harfbuzz.nix makes this
# harfbuzz the set's.
{ lib }:
self: super:
let
  bootstrap = super.freetype.overrideAttrs (oa: {
    pname = "freetype-bootstrap";
    configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-harfbuzz=no" ];
  });
  # `harfbuzz.pc` declares `Requires: freetype2, glib-2.0, graphite2` but
  # nixpkgs only propagates graphite2: glib is promoted here, freetype2 comes
  # from this freetype, which propagates harfbuzz. `self.glib` (post-overlay),
  # not `super` — else vanilla mingw glib drags libsysprof-capture and a
  # second glib derivation into the closure.
  harfbuzz = (super.harfbuzz.override { freetype = bootstrap; }).overrideAttrs (oa: {
    propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.glib ];
    # Skip test binaries — they statically link the full closure into many
    # ~150 MB `.exe` files, blowing the build disk; no consumer needs them.
    mesonFlags = (oa.mesonFlags or [ ]) ++ [ "-Dtests=disabled" ];
  });
in
super.freetype.overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-harfbuzz=yes" ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ harfbuzz ];
  # harfbuzz.pc requires freetype2, which is this build.
  env = (oa.env or { }) // {
    HARFBUZZ_CFLAGS = "-I${lib.getDev harfbuzz}/include/harfbuzz";
    HARFBUZZ_LIBS = "-L${lib.getLib harfbuzz}/lib -lharfbuzz";
  };
  # configure writes HARFBUZZ_LIBS into Libs; name the module instead, so
  # harfbuzz's own requirements (graphite2, glib) reach the link.
  postFixup = (oa.postFixup or "") + ''
    pc="''${!outputDev}"/lib/pkgconfig/freetype2.pc
    sed -i -e 's| -L${lib.getLib harfbuzz}/lib -lharfbuzz||' \
      -e 's|^Requires:[ ]*$|Requires: harfbuzz|;t' -e 's|^Requires: \(.*\)$|Requires: \1, harfbuzz|' "$pc"
    grep -q '^Requires:.*harfbuzz' "$pc" || { echo "freetype2.pc: no harfbuzz" >&2; exit 1; }
    if grep -q -- -lharfbuzz "$pc"; then echo "freetype2.pc: -lharfbuzz left" >&2; exit 1; fi
  '';
  passthru = (oa.passthru or { }) // { unpinHarfbuzz = harfbuzz; };
})
