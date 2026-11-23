# No run-time harfbuzz. nixpkgs builds freetype without harfbuzz (harfbuzz
# depends on freetype, not the other way round), and then configure's `auto`
# falls back to `dynamic`: the autohinter dlopens libharfbuzz at run time. A
# shipped static binary must not load a foreign library that way — on macOS
# the dlopen can succeed with whatever libharfbuzz.0.dylib is found. The
# Windows copy of this fix lives in mingw-overlay/freetype.nix.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    pkgs.freetype.overrideAttrs (oa: {
      configureFlags = (oa.configureFlags or [ ]) ++ [ "--with-harfbuzz=no" ];
    });
}
