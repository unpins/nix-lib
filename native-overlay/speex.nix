# Darwin-only fix. Linux speex caches cleanly (no churn).
#
# speex (the codec) propagates speexdsp + links against fftw when
# `withFft = true` (default). Both transitively pull openmp's
# broken-on-darwin python chain (see [[fftw]] / [[llvm-openmp]]).
# Drop FFT support entirely on darwin: `withFft = false` controls
# the echo-cancel demo code's fftw link (ffmpeg's libspeex probe
# uses only encoder/decoder, no FFT); also propagate the fixed
# speexdsp so the dsp closure stays clean.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then pkgs.speex.override {
  withFft = false;
  speexdsp = lib.nativeFixes.speexdsp pkgs;
}
else pkgs.speex
