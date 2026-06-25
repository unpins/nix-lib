# Same meson cross-file mismatch as libopus.nix: on darwin-aarch64 nixpkgs
# writes `cpu_family = 'arm64'` (uncanonicalized), so dav1d's
# `cpu_family().startswith('arm')` treats it as ARM-32 and assembles
# `src/arm/32/*.S` with arm64 clang (".syntax unified" etc.). Two
# substitutions: accept 'arm64' wherever 'aarch64' is matched, and exclude
# 'arm64' from the startswith('arm') ARM-32 branch.
{ lib }:
pkgs:
pkgs.dav1d.overrideAttrs (oa: {
  postPatch = (oa.postPatch or "") + ''
    # Patch every meson.build that branches on cpu_family — checked
    # locations include the top-level, src/, and tests/ (the latter
    # builds checkasm with its own arch dispatch). find -name keeps it
    # robust to upstream adding more.
    find . -name 'meson.build' -print0 | while IFS= read -r -d "" f; do
      substituteInPlace "$f" \
        --replace-quiet \
          "host_machine.cpu_family() == 'aarch64'" \
          "(host_machine.cpu_family() == 'aarch64' or host_machine.cpu_family() == 'arm64')" \
        --replace-quiet \
          "host_machine.cpu_family().startswith('arm')" \
          "(host_machine.cpu_family().startswith('arm') and host_machine.cpu_family() != 'arm64')"
    done
  '';
})
