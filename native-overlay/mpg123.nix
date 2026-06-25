# nixpkgs `mpg123` defaults `withPulse = true` on Linux, pulling
# `libpulseaudio` which is `badPlatforms.isStatic` (dynamic-load-only on musl).
# `libOnly = true` drops the CLI players + audio backends; we only need the
# `libmpg123` decoder. `withConplay = false` satisfies the matching assertion
# (`withConplay → !libOnly`).
{ lib }:
pkgs:
pkgs.mpg123.override {
  libOnly = true;
  withConplay = false;
}
