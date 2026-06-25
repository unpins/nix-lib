# pkgsStatic.libvpx — darwin-only fixes (mingw via mingw-overlay/libvpx.nix;
# linux passes through). Two stacked darwin issues:
#
# 1. package.nix reads `osxMinVersion`, renamed to `darwinMinVersion` upstream
#    but not updated here → eval crashes `attribute 'osxMinVersion' missing`.
#    Inject a stand-in; real deployment target set via configureFlags below.
#
# 2. With the bridged value the target maps to `darwin14` (macOS 10.10) and
#    configure injects `-mmacosx-version-min=10.10`, which the 14.4 SDK rejects
#    on `CLOCK_MONOTONIC_RAW` (10.12+). Rewrite the target to `darwin23`.
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
