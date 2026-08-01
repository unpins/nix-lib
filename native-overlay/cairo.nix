# nixpkgs cairo's cross meson-file looks up `ipc_rmid_deferred_release` by
# kernel name against an attrset missing 'darwin', so cross-within-darwin
# (aarch64 ↔ x86_64, only the macos-14 CI path) throws "Unknown value for
# ipc_rmid_deferred_release on darwin" during mesonFlags eval.
#
# overrideAttrs must NEVER read `oa.mesonFlags` — forcing the list re-triggers
# the throw before our value lands — so reconstruct it: mirror the pinned cairo
# mesonFlags + pkgsStatic flags, with deferred-release set 'false' (valid, and
# correct: macOS shmctl(IPC_RMID) forbids later attaches). The standard
# [host_machine] cross-file is re-added by the meson setup hook.
{ lib }:
pkgs:
let
  isCrossDarwin = pkgs.stdenv.hostPlatform.isDarwin
    && !(pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform);
in
if !isCrossDarwin
then pkgs.cairo
else
  pkgs.cairo.overrideAttrs (_: {
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
