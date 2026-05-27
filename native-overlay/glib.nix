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
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  pkgs.glib.overrideAttrs (oa: {
    preConfigure = (oa.preConfigure or "") + ''
      cat > "$NIX_BUILD_TOP/objc-cross.conf" <<EOF
      [binaries]
      objc = '$CC'
      objcpp = '$CXX'
      EOF
      mesonFlagsArray+=("--cross-file=$NIX_BUILD_TOP/objc-cross.conf")
    '';
  })
else
  pkgs.glib
