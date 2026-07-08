# nixpkgs' meson cross-file omits `objc`/`objcpp` from [binaries], and meson
# refuses `add_languages('objc')` in cross mode without them. glib calls it
# under `host_system == 'darwin'`, so a linux→darwin cross-eval (the .drv is
# generated in cross mode even though the build runs native) aborts with "'objc'
# compiler binary not defined in cross file". clang handles `.m`/`.mm`, so point
# both at `$CC`/`$CXX`; append via `mesonFlagsArray` so `$CC` expands at build
# time. Reusable for any darwin-objc meson package.
#
# Second fix (glib 2.88.1): `subsystem = host_machine.subsystem()` can't
# autodetect in cross mode ("Subsystem not defined"). Set `subsystem = 'macos'`
# in [host_machine] via the same file (both targets are desktop macOS).
#
# Third fix (glib 2.88.1): gio/meson.build hard-requires arpa/nameser.h (its
# `C_IN` resolver check errors out otherwise), but nixpkgs' apple-sdk ships only
# ftp/inet/telnet/tftp under arpa/ — the DNS resolver headers live in the
# separate `darwin.libresolv`. The normal darwin stdenv pulls them via apple-sdk's
# setup hook, but the engine drops apple-sdk (SDKROOT instead), so add libresolv
# explicitly. Headers only: the res_*/ns_* symbols are in libSystem (allow-listed).
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  let
    hp = pkgs.stdenv.hostPlatform;
    # meson REPLACES (not merges) a [host_machine] redefined by a later
    # --cross-file, so re-emit the full section, not just `subsystem`.
    cpuFamily = if hp.isAarch64 then "aarch64" else "x86_64";
  in
  pkgs.glib.overrideAttrs (oa: {
    buildInputs = (oa.buildInputs or [ ]) ++ [ pkgs.darwin.libresolv ];
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
