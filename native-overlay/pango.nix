# pango's `meson.build` calls `add_languages('objc')` under `darwin` for
# the Core Text font backend. Same failure mode as `nativeFixes.glib`:
# nixpkgs' linux→darwin meson cross-file lacks the `objc`/`objcpp`
# binary entries, so the configure aborts with
#   ERROR: 'objc' compiler binary not defined in cross file [binaries]
#
# Same fix: append a cross-file pointing `objc`/`objcpp` at `$CC`/`$CXX`
# (clang). Meson MERGES the [binaries] section across cross-files, so
# objc/objcpp add to the primary's llvm-config/rust/cmake.
#
# 26.05 (pango 1.57.1, meson.build:60): `subsystem = host_machine.subsystem()`
# under darwin. Forcing the objc cross-file puts meson in cross mode, where it
# can't autodetect the subsystem → `ERROR: Subsystem not defined`. Meson
# REPLACES the [host_machine] section (unlike [binaries] it does not merge),
# so re-emit it COMPLETE (system/cpu_family/cpu/endian) + subsystem, else
# `ERROR: Machine info is currently {'subsystem': 'macos'}`. Same as
# nativeFixes.glib. See [[project_unpins_2605_release_sweep]] DARWIN MESON.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  let
    hp = pkgs.stdenv.hostPlatform;
    cpuFamily = if hp.isAarch64 then "aarch64" else "x86_64";
  in
  pkgs.pango.overrideAttrs (oa: {
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
  pkgs.pango
