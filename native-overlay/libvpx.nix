# pkgsStatic.libvpx — darwin-only fixes (mingw is handled by
# mingw-overlay/libvpx.nix); linux passes through.
#
# Two stacked darwin issues:
#
# 1. nixpkgs `libvpx/package.nix` reads
#    `stdenv.hostPlatform.osxMinVersion`, which was renamed to
#    `darwinMinVersion` (`lib/systems/default.nix:364`). The
#    package wasn't updated, so eval crashes with `attribute
#    'osxMinVersion' missing`. Bridge the rename by injecting a
#    stand-in value into hostPlatform — the real deployment target
#    is set via configureFlags below.
#
# 2. With the bridged value, libvpx's package.nix maps to at most
#    `darwin14` (macOS 10.10), and configure then injects
#    `-mmacosx-version-min=10.10` into CFLAGS+LDFLAGS — which the
#    macOS 14.4 SDK rejects on `CLOCK_MONOTONIC_RAW` (10.12+).
#    libvpx supports up to `darwin25`; rewrite the configure target
#    to `darwin23` (macOS 14, matching nixpkgs' `darwinMinVersion`).
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then
  (pkgs.libvpx.override {
    stdenv = pkgs.stdenv // {
      hostPlatform = pkgs.stdenv.hostPlatform // {
        osxMinVersion = "10.10";
      };
    };
  }).overrideAttrs (oa: {
    configureFlags =
      (builtins.filter
        (f: !(lib.hasPrefix "--target=x86_64-darwin" f
          || lib.hasPrefix "--target=arm64-darwin" f
          || lib.hasPrefix "--target=aarch64-darwin" f))
        oa.configureFlags)
      ++ [
        "--target=${
          if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"
        }-darwin23-gcc"
      ];
  })
else pkgs.libvpx
