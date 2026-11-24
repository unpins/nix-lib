# glib calls `add_languages('objc')` under `host_system == 'darwin'`, which the
# linux→darwin cross-file can't satisfy — see `lib.withDarwinMesonObjc`. The
# .drv is generated in cross mode even though the build runs native, so this
# hits cross-eval too.
#
# gio/meson.build hard-requires arpa/nameser.h (its `C_IN` resolver check errors
# out otherwise), but nixpkgs' apple-sdk ships only ftp/inet/telnet/tftp under
# arpa/ — the DNS resolver headers live in the separate `darwin.libresolv`. The
# normal darwin stdenv pulls them via apple-sdk's setup hook, but the engine
# drops apple-sdk (SDKROOT instead), so add libresolv explicitly. Headers only:
# the res_*/ns_* symbols are in libSystem (allow-listed).
#
# Auto-wired, like graphite2: freetype links harfbuzz (freetype.nix), which
# links glib, so every darwin static scope with freetype builds glib. The
# marker keeps a consumer that also applies the fix by hand from doing it twice.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin && !(pkgs.glib.unpinDarwinFixed or false) then
      lib.withDarwinMesonObjc pkgs
        (pkgs.glib.overrideAttrs (oa: {
          buildInputs = (oa.buildInputs or [ ]) ++ [ pkgs.darwin.libresolv ];
          passthru = (oa.passthru or { }) // { unpinDarwinFixed = true; };
        }))
    else
      pkgs.glib;
}
