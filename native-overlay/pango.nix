# pango's `meson.build` calls `add_languages('objc')` for Core Text, which the
# linux→darwin cross-file can't satisfy — see `lib.withDarwinMesonObjc`.
# See [[project_unpins_2605_release_sweep]] DARWIN MESON.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then lib.withDarwinMesonObjc pkgs pkgs.pango
else pkgs.pango
