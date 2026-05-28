# nixpkgs cairo generates a meson cross-file when `buildPlatform.canExecute
# hostPlatform` is false. The cross-file embeds an
# `ipc_rmid_deferred_release` value looked up by
# `stdenv.hostPlatform.parsed.kernel.name` against an attrset that lists
# linux / freebsd / openbsd / netbsd — 'darwin' is missing, so cross-
# within-darwin (aarch64-darwin ↔ x86_64-darwin) trips:
#     error: Unknown value for ipc_rmid_deferred_release on darwin
# at pkgs/by-name/ca/cairo/package.nix:106 during mesonFlags eval.
#
# `overrideAttrs` can replace `mesonFlags` but must NEVER read
# `oa.mesonFlags` — reading forces the upstream list and triggers the
# throw before our value is computed. Reconstruct the list from scratch:
# the only flag cairo would add for the darwin / static path is the
# cross-file itself (the `-Dtee=enabled` optional drops on darwin / mingw
# / static). Supply an equivalent cross-file with the deferred-release
# property set to `'no'` (macOS has no SysV IPC RMID-deferred semantics).
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
    "--cross-file=${builtins.toFile "cairo-darwin-cross.conf" ''
      [properties]
      ipc_rmid_deferred_release = 'no'
    ''}"
  ];
})
