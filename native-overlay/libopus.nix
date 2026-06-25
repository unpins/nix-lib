# Some nixpkgs revs report `darwin-aarch64.uname.processor = "arm64"`, which
# nixpkgs writes verbatim into meson's `cpu_family` without canonicalizing to
# `aarch64`. opus meson.build:390 only matches `['arm', 'aarch64']`, so the
# NEON branch is skipped and the build errors with "no intrinsics support for
# arm64". Add 'arm64' to the accepted list so the NEON probe runs.
{ lib }:
pkgs:
pkgs.libopus.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace meson.build \
      --replace-fail "in ['arm', 'aarch64']" \
                     "in ['arm', 'aarch64', 'arm64']"
  '';
})
