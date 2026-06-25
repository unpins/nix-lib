# Darwin-only fix. speex links fftw when `withFft = true` (default), pulling
# openmp's broken-on-darwin python chain (see [[fftw]] / [[llvm-openmp]]).
# `withFft = false` drops it (ffmpeg's libspeex probe uses no FFT); also
# propagate the fixed speexdsp.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then pkgs.speex.override {
  withFft = false;
  speexdsp = lib.nativeFixes.speexdsp pkgs;
}
else pkgs.speex
