# gdk-pixbuf builds four host tools (gdk-pixbuf-csource / -pixdata /
# -query-loaders, pixops/timescale) and links them against gio, whose darwin
# `gio-2.0.pc` carries `-lresolv` in Libs.private. The token has no `-L` of its
# own: the normal darwin stdenv resolves it through apple-sdk's setup hook, but
# the engine drops apple-sdk (SDKROOT instead) and nixpkgs' apple-sdk ships no
# libresolv at all, so the tools die with `ld64.lld: library not found for
# -lresolv`. Same root cause as native-overlay/glib.nix, and the same remedy
# native-overlay/librsvg.nix uses for the archive that carries the references:
# put `darwin.libresolv` on the search path.
#
# Second, darwin static: nixpkgs' `preFixup` rewrites
# `@rpath/libgdk_pixbuf-2.0.0.dylib` in every installed tool ("the
# fixDarwinDylibNames hook doesn't patch binaries"). A static build produces no
# such dylib and no binary carries that load command, so the rewrite has nothing
# to change — but it still runs `install_name_tool`, which the engine's darwin
# toolchain does not ship (cctools comes with the stock darwin bintools the
# engine replaces), and the phase dies with `command not found`. Drop the dead
# hook rather than drag cctools in; it is the whole of `preFixup` upstream.
#
# Auto-wired: gdk-pixbuf arrives transitively (libjxl/libavif propagate it even
# with their loader plugins off), so a consumer that fixes it by hand only
# reaches the copy IT names — same reasoning as native-overlay/graphite2.nix.
# Identity off darwin, so linux/mingw keep their hashes.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.gdk-pixbuf.overrideAttrs (oa: {
        buildInputs = (oa.buildInputs or [ ]) ++ [ pkgs.darwin.libresolv ];
      } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isStatic {
        preFixup = "";
      })
    else
      pkgs.gdk-pixbuf;
}
