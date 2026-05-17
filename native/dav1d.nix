# Same Apple-Silicon / meson cross-file mismatch as native/libopus.nix:
# nixpkgs writes `cpu_family = 'arm64'` (from uname.processor) into the
# meson cross-file on darwin-aarch64, and meson doesn't canonicalize to
# 'aarch64'. dav1d treats `cpu_family().startswith('arm')` as ARM-32 and
# tries to assemble `src/arm/32/*.S` (32-bit mnemonics) with the arm64
# clang → "unknown directive .syntax unified", "vector register
# expected", etc. dav1d already has a `cpu() == 'arm64'` fallback in
# src/meson.build:92 (line 92) and meson.build:379-380, but for nixpkgs
# the values come out swapped (cpu_family='arm64', cpu='aarch64') so the
# fallback doesn't fire.
#
# Two substitutions: (a) every `cpu_family() == 'aarch64'` accepts
# 'arm64' too, (b) every `cpu_family().startswith('arm')` excludes
# 'arm64' explicitly. Together they route arm64 to the 64-bit asm
# dispatch and keep ARCH_AARCH64 / ARCH_ARM cdata booleans coherent.
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
