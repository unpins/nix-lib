# pkgsStatic.libopenmpt propagates audio backends only the openmpt123 CLI
# uses; library consumers (ffmpeg's demuxer) just want libopenmpt.a. Cut all
# four, plus the CLI flags and the now-empty `$bin` output:
#
# - mpg123 defaults withPulse on Linux → libpulseaudio is badPlatforms.isStatic.
#   Swap for the lib-only variant via [[mpg123]].
# - portaudio (drags alsa-lib + libjack2) and libsndfile are CLI-only.
# - usePulseAudio=false is libopenmpt's own knob, also needed to skip the
#   libpulseaudio link.
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
  # libopenmpt.pc declares `Requires.private: libmpg123`, so `pkg-config
  # --static libopenmpt` cascades into libmpg123.pc; mpg123 must be propagated
  # (not just buildInputs) or ffmpeg's PKG_CONFIG_PATH misses its `.dev` and
  # fails. Propagate both `.out` (libmpg123.a) and `.dev` (libmpg123.pc).
  propagatedBuildInputs = builtins.filter
    (d:
      let p = d.pname or null; in
      p != "portaudio" && p != "libsndfile" && p != "libpulseaudio")
    (oa.propagatedBuildInputs or [ ])
    ++ [ mpg123' mpg123'.dev ];
})
