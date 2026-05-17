# nixpkgs revs around 2026-05 report `darwin-aarch64.uname.processor =
# "arm64"` (transitional naming; HEAD now returns "aarch64"). The meson
# cross-file template in nixpkgs writes `cpu_family` from that value
# verbatim, and meson does not canonicalize `arm64` → `aarch64`. opus
# meson.build:390 only matches `['arm', 'aarch64']`, so the ARM/NEON
# intrinsics branch is skipped and the build errors at line 617 with
# "intrinsics option enabled, but no intrinsics support for arm64".
#
# One-line patch: add 'arm64' to the accepted list so the existing
# `cc.links(vmlaq_f32 ...)` probe runs and enables NEON.
{ lib }:
pkgs:
pkgs.libopus.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace meson.build \
      --replace-fail "in ['arm', 'aarch64']" \
                     "in ['arm', 'aarch64', 'arm64']"
  '';
})
