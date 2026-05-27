# Darwin-only fix. Linux speexdsp caches cleanly (no churn).
#
# speexdsp's `--enable-fft=fftw3` (the nixpkgs default via
# `withFftw3 = true`) propagates `pkgs.fftw`, which on
# pkgsStatic-darwin drags openmp's broken Python chain (see
# [[fftw]] / [[llvm-openmp]] for the layered issues). Until LLVM
# static-darwin builds clean, drop fftw3 entirely on darwin.
# speexdsp falls back to its kissfft backend (bundled, header-only)
# for FFTs — consumers using only speex *codec* don't exercise FFT
# anyway (echo cancel / AGC consume it; ffmpeg's `--enable-libspeex`
# does not).
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then pkgs.speexdsp.override { withFftw3 = false; }
else pkgs.speexdsp
