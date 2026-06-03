# nixpkgs' meson cross-file (`pkgs/build-support/lib/meson.nix`) writes a
# `[binaries]` section with only `llvm-config`, `rust`, and `cmake`. C/C++
# compilers fall back to `$CC`/`$CXX` from cc-wrapper, but Objective-C does
# **not** — meson refuses any `add_languages('objc')` call in cross mode
# unless `objc` (and `objcpp` for `.mm`) is explicit in the cross-file.
#
# glib hits this on darwin: `meson.build` calls `add_languages('objc')`
# under `if host_system == 'darwin'`, which fails with
#   ERROR: 'objc' compiler binary not defined in cross file [binaries]
# when we cross-eval x86_64-linux → x86_64-darwin (even though the actual
# build dispatches to a native darwin builder, the .drv was generated in
# cross mode and embeds the linux→darwin cross-file).
#
# clang handles `.m`/`.mm` natively, so we point both at `$CC`/`$CXX`. The
# extra cross-file is appended via `mesonFlagsArray` (a bash array picked
# up by `mesonConfigurePhase` in meson's setup-hook) so that `$CC` shell-
# expands at build time.
#
# Meson merges multiple `--cross-file` arguments left-to-right with later
# values overriding earlier — adding a partial file with only the
# `[binaries].objc{,pp}` entries is safe and leaves the primary cross-file
# untouched. Reusable for any other glib/gobject-introspection/libsoup-
# class meson package that pulls darwin objc.
#
# Second darwin fix (nixos-26.05, glib 2.88.1): meson.build:84 does
# `subsystem = host_machine.subsystem()` under `host_system == 'darwin'`.
# In cross mode meson can't autodetect the subsystem and aborts with
#   ERROR: Subsystem not defined or could not be autodetected
# (a native build on a Mac autodetects it; our linux→darwin cross-eval
# can't). nixpkgs' generated cross-file's `[host_machine]` omits it, so we
# merge `subsystem = 'macos'` into host_machine via the same extra
# cross-file (meson merges sections per-key, so a partial [host_machine]
# just adds the one key). Both unpins darwin targets are desktop macOS.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  let
    hp = pkgs.stdenv.hostPlatform;
    # Mirror nixpkgs' generated [host_machine] (build-support/lib/meson.nix):
    # meson REPLACES a section when a later --cross-file redefines it (it does
    # not merge [host_machine] per-key), so a partial file with only
    # `subsystem` drops system/cpu/endian and meson aborts "Machine info is
    # currently {'subsystem': 'macos'}". Re-emit the full section + subsystem.
    cpuFamily = if hp.isAarch64 then "aarch64" else "x86_64";
  in
  pkgs.glib.overrideAttrs (oa: {
    preConfigure = (oa.preConfigure or "") + ''
      cat > "$NIX_BUILD_TOP/objc-cross.conf" <<EOF
      [binaries]
      objc = '$CC'
      objcpp = '$CXX'

      [host_machine]
      system = 'darwin'
      cpu_family = '${cpuFamily}'
      cpu = '${hp.parsed.cpu.name}'
      endian = 'little'
      subsystem = 'macos'
      EOF
      mesonFlagsArray+=("--cross-file=$NIX_BUILD_TOP/objc-cross.conf")
    '';
  })
else
  pkgs.glib
