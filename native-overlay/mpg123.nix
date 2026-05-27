# nixpkgs `mpg123` default on Linux comes with `withPulse = true`,
# pulling `libpulseaudio` which is `badPlatforms.isStatic` (PulseAudio
# is dynamic-load-only on musl). Consumers needing only `libmpg123`
# (the decoder library, not the CLI player) avoid the audio backend
# chain by setting `libOnly = true` — drops the `mpg123` / `mpg123pa`
# / `out123` CLI binaries and the ALSA/Pulse/JACK output drivers.
#
# `withConplay = false` is the matching assertion (`withConplay →
# !libOnly`); leaving the legacy CLI on without the main one is
# useless, so we kill both.
{ lib }:
pkgs:
pkgs.mpg123.override {
  libOnly = true;
  withConplay = false;
}
