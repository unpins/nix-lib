# pango's `meson.build` calls `add_languages('objc')` under `darwin` for
# the Core Text font backend. Same failure mode as `nativeFixes.glib`:
# nixpkgs' linux→darwin meson cross-file lacks the `objc`/`objcpp`
# binary entries, so the configure aborts with
#   ERROR: 'objc' compiler binary not defined in cross file [binaries]
#
# Same fix: append a partial cross-file pointing `objc`/`objcpp` at
# `$CC`/`$CXX` (clang). Meson merges multiple `--cross-file` arguments
# left-to-right, so the original cross-file is left intact.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  pkgs.pango.overrideAttrs (oa: {
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
  pkgs.pango
