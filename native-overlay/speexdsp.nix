# Darwin-only fix. speexdsp's `withFftw3 = true` (default) propagates
# `pkgs.fftw`, which drags openmp's broken Python chain on pkgsStatic-darwin
# (see [[fftw]] / [[llvm-openmp]]). `withFftw3 = false` falls back to bundled
# kissfft — ffmpeg's `--enable-libspeex` doesn't exercise FFT anyway.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then pkgs.speexdsp.override { withFftw3 = false; }
else pkgs.speexdsp
