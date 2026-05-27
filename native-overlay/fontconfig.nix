# fontconfig 2.17.1 ships two tests that compare sysroot paths as plain
# strings:
#   - test-issue110
#   - test-d1f48f11
# On darwin, `/tmp` is a symlink to `/private/tmp`. The tests write to
# `/tmp/...` and the code-under-test reads the canonicalised
# `/private/tmp/...`, so the string compare fails:
#   E: failed to compare for sysroot:
#      /private/tmp/fc-…/00-foo.conf, /tmp/fc-…/00-foo.conf
#
# Upstream test bug, not a fontconfig defect — every other test (10/13)
# passes. nixpkgs leaves `doCheck` on the platform default, which is
# enabled for darwin. Skip the suite there; consumers (cairo, pango,
# librsvg) only care about the installed library + .pc, not the test
# binaries.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  pkgs.fontconfig.overrideAttrs (oa: {
    doCheck = false;
  })
else
  pkgs.fontconfig
