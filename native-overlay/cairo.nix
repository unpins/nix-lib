# nixpkgs cairo appends a meson cross-file to `mesonFlags` when
# `buildPlatform.canExecute hostPlatform` is false. That cross-file
# embeds an `ipc_rmid_deferred_release` value looked up by
# `stdenv.hostPlatform.parsed.kernel.name` against an attrset listing
# only linux / freebsd / netbsd / windows — 'darwin' is missing, so
# cross-within-darwin (aarch64-darwin ↔ x86_64-darwin) trips:
#     error: Unknown value for ipc_rmid_deferred_release on darwin
# at pkgs/by-name/ca/cairo/package.nix:106 during mesonFlags eval.
# (Native x86_64-darwin from the Intel Mac doesn't cross, so it never
# fires there; only the macos-14 CI path, building the other arch.)
#
# `overrideAttrs` must NEVER read `oa.mesonFlags` — forcing the list
# re-triggers the throw before our value lands. So reconstruct it.
# The reconstruction mirrors the pinned nixpkgs cairo `mesonFlags`
# (the fixed knobs + glib/xlib/xcb/tests toggles as they resolve on
# darwin pkgsStatic) plus the pkgsStatic static-library flags, with
# the cross-file's deferred-release set to a VALID value. cairo's
# meson.build accepts only 'true' / 'false' / 'auto' for this
# property; macOS shmctl(IPC_RMID) forbids subsequent attaches (no
# deferred-release), so 'false' is both valid and correct. The
# standard meson `[host_machine]` cross-file is re-added by the meson
# setup hook at configure time, so it's fine to omit here.
{ lib }:
pkgs:
let
  isCrossDarwin = pkgs.stdenv.hostPlatform.isDarwin
               && !(pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform);
in
if !isCrossDarwin
then pkgs.cairo
else pkgs.cairo.overrideAttrs (_oa: {
  mesonFlags = [
    "-Dgtk_doc=true"
    "-Dsymbol-lookup=disabled"
    "-Dspectre=disabled"
    "-Dglib=enabled"
    "-Dtests=disabled"
    "-Dxlib=enabled"
    "-Dxcb=enabled"
    "-Ddefault_library=static"
    "-Ddefault_both_libraries=static"
    "--cross-file=${builtins.toFile "cairo-darwin-cross.conf" ''
      [properties]
      ipc_rmid_deferred_release = 'false'
    ''}"
  ];
})
