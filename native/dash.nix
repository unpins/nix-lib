# Disable libedit on darwin only. nixpkgs 25.11's dash 0.5.13.2
# tightened the libedit probe (AC_CHECK_LIB history_init), and darwin
# pkgsStatic's libedit doesn't satisfy that probe — almost certainly
# because the static link needs `-liconv` (a darwin-specific quirk
# pkg-config doesn't surface). Without working line-editing libs,
# configure aborts with "Can't find libedit." instead of falling back.
#
# Linux pkgsStatic.dash keeps libedit (CI green across musl variants),
# so users on the dominant platform get arrow-key history. Darwin
# matches Windows in losing it — both rely on bash/zsh for interactive
# work anyway. TODO: try `LIBS="$LIBS -liconv"` preConfigure on darwin
# to restore it; needs a darwin runner to iterate against.
{ lib }:
pkgs:
let p = pkgs.pkgsStatic; in
if p.stdenv.hostPlatform.isDarwin then
  p.dash.overrideAttrs (oa: {
    buildInputs = [ ];
    configureFlags = [ "--without-libedit" ];
    preConfigure = "";
  })
else
  p.dash
