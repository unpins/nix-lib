# libopenmpt in pkgsStatic propagates audio backends that only the
# CLI player (`openmpt123`) consumes — pure library consumers
# (e.g. ffmpeg's libopenmpt demuxer) just want `libopenmpt.a`. The
# chain:
#
# - `mpg123` defaults `withPulse = true` on Linux → `libpulseaudio`
#   has `badPlatforms.isStatic`. Swap mpg123 for the lib-only
#   variant via [[mpg123]].
# - `portaudio` is propagated for the `openmpt123` CLI; in pkgsStatic
#   it adds `alsa-lib + libjack2`. Useless for library consumers.
# - `libsndfile` same — only CLI.
# - `usePulseAudio = false` is libopenmpt's own knob; independent of
#   mpg123's flag, also needed to skip the libpulseaudio link.
#
# Cut all four. Drop the matching configure flags and the `$bin`
# output (there's no CLI left to land in it).
{ lib }:
pkgs:
let
  mpg123' = lib.nativeFixes.mpg123 pkgs;
in
(pkgs.libopenmpt.override {
  usePulseAudio = false;
  mpg123 = mpg123';
}).overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ]) ++ [
    "--without-portaudio"
    "--without-portaudiocpp"
    "--without-sndfile"
    "--disable-openmpt123"
    "--disable-tests"
    "--disable-examples"
  ];
  outputs = [ "out" "dev" ];
  buildInputs = builtins.filter
    (d:
      let p = d.pname or null; in
      p != "portaudio" && p != "libsndfile")
    (oa.buildInputs or [ ]);
  # libopenmpt.pc declares `Requires.private: libmpg123` (it's a build-time
  # dep of the static lib path). Consumers calling
  # `pkg-config --static libopenmpt` cascade into libmpg123.pc; if mpg123
  # is only in `buildInputs` (not propagated), ffmpeg's PKG_CONFIG_PATH
  # doesn't include mpg123's `.dev` and fails with
  # `Package 'libmpg123' was not found, required by libopenmpt`.
  # Propagate both `.out` (libmpg123.a) and `.dev` (libmpg123.pc).
  propagatedBuildInputs = builtins.filter
    (d:
      let p = d.pname or null; in
      p != "portaudio" && p != "libsndfile" && p != "libpulseaudio")
    (oa.propagatedBuildInputs or [ ])
    ++ [ mpg123' mpg123'.dev ];
})
