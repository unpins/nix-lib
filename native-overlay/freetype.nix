# harfbuzz linked into freetype, statically. Without harfbuzz at build time
# (nixpkgs' choice: harfbuzz depends on freetype, not the other way round)
# configure's `auto` falls back to `dynamic`, and the autohinter dlopens
# libharfbuzz at run time. Under Nix that works because the app has already
# loaded harfbuzz; in a static binary it cannot see its own copy — on Linux the
# dlopen just fails, on macOS it loads whatever libharfbuzz.0.dylib the system
# has. Linking it in keeps the autohinter's OpenType coverage everywhere.
#
# The cycle is broken the way upstream documents: harfbuzz is built against a
# harfbuzz-less freetype, then freetype against that harfbuzz. The two freetypes
# have the same API; harfbuzz only takes headers and a pkg-config name from
# the bootstrap one, so it stops propagating it and the final link sees one
# libfreetype.a. harfbuzz.nix makes this harfbuzz the scope's. The Windows copy
# of this fix lives in mingw-overlay/freetype.nix.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    let
      bootstrap = pkgs.freetype.overrideAttrs (oa: {
        pname = "freetype-bootstrap";
        configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-harfbuzz=no" ];
      });
      harfbuzz = (pkgs.harfbuzz.override { freetype = bootstrap; }).overrideAttrs (oa: {
        postFixup = (oa.postFixup or "") + ''
          for f in "''${!outputDev}"/nix-support/propagated-build-inputs; do
            [ -e "$f" ] && sed -i 's|${lib.getDev bootstrap}||; s|${lib.getLib bootstrap}||' "$f"
          done
        '';
      });
    in
    pkgs.freetype.overrideAttrs (oa: {
      configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-harfbuzz=yes" ];
      propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ harfbuzz ];
      # harfbuzz.pc requires freetype2, which is this build: name the flags
      # instead of asking pkg-config.
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
    });
}
