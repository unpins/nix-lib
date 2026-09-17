# Two fixes, both for the static builds we ship.
#
# 1. Font directories when there is no fonts.conf. nixpkgs configures
#    `--with-default-fonts=${dejavu_fonts.minimal}`, a store path, as the
#    directory fontconfig falls back to when it finds no configuration. A
#    shipped binary never has that path, and macOS and Windows have no
#    /etc/fonts either — so there fontconfig knew no fonts at all: ffmpeg's
#    `drawtext` without `fontfile=` failed with "Cannot find a valid font for
#    the family Sans". Without the flag, configure picks upstream's per-OS
#    default (/usr/share/fonts on Linux, the /System/Library and /Library font
#    folders on macOS), which is what the fallback exists for. The Windows copy
#    of this fix lives in mingw-overlay/fontconfig.nix.
#
# 2. darwin: test-issue110 / test-d1f48f11 compare sysroot paths as plain
#    strings; `/tmp` symlinks to `/private/tmp`, so the test writes `/tmp/...`
#    and reads the canonicalised `/private/tmp/...`. Upstream test bug (the
#    other 10/13 pass); consumers only need the library + .pc.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    pkgs.fontconfig.overrideAttrs (oa: {
      configureFlags = builtins.filter
        (f: !(lib.hasPrefix "--with-default-fonts=" f))
        (oa.configureFlags or [ ]);
    } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      doCheck = false;
    });
}
