# fontconfig 2.17.1's test-issue110 / test-d1f48f11 compare sysroot paths as
# plain strings; on darwin `/tmp` symlinks to `/private/tmp`, so the test writes
# `/tmp/...` and reads the canonicalised `/private/tmp/...` → compare fails.
# Upstream test bug (other 10/13 pass); doCheck defaults on for darwin. Skip it
# there — consumers only need the library + .pc.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  pkgs.fontconfig.overrideAttrs (oa: {
    doCheck = false;
  })
else
  pkgs.fontconfig
