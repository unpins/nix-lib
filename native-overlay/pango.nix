# Darwin meson cross-file fixes, same family as `nativeFixes.glib`:
#
# 1. pango's `meson.build` does `add_languages('objc')` for Core Text, but the
#    linux→darwin meson cross-file lacks `objc`/`objcpp` entries → configure
#    aborts. Append a cross-file pointing them at `$CC`/`$CXX`; meson MERGES
#    [binaries] across cross-files.
#
# 2. The objc cross-file forces cross mode, so meson can't autodetect
#    `subsystem` → `ERROR: Subsystem not defined`. Unlike [binaries], meson
#    REPLACES [host_machine], so re-emit it complete + subsystem.
# See [[project_unpins_2605_release_sweep]] DARWIN MESON.
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
