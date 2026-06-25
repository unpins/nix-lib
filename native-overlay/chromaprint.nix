# pkgsStatic.chromaprint, four fixes:
#
# 1. `withTools/withExamples = false`. They pull ffmpeg-headless (for the fpcalc
#    CLI; the lib never refs libav*) → circular dep + libpulseaudio
#    (badPlatforms.isStatic on musl).
#
# 2. `buildInputs = [ ]` (zlib was for fpcalc); on mingw propagate
#    windows.mcfgthreads — libstdc++ refs `_MCF_*` (mingw gcc is
#    `--enable-threads=mcf`). Both `.dev` (the `.pc`) and `.out`
#    (`libmcfgthread.a`); a bare ref only splices `.dev`.
#
# 3. `.pc Libs.private` append. `libchromaprint.a` is C++ → static link probes
#    fail with `__cxa_*`/`cosf` undef. Darwin's `FFT_LIB=vdsp` also refs the
#    Accelerate framework.
#
# 4. MinGW only: `.pc Cflags += -DCHROMAPRINT_NODLL`. Else the header decorates
#    `CHROMAPRINT_API` with `__declspec(dllimport)`, so static consumers emit
#    `__imp_chromaprint_*` the plain `.a` symbols can't satisfy. See
#    [[mingw-dllimport-static-pattern]].
#
# Can't split mingw out: the `withTools` override-arg re-invokes the function,
# dropping any `super.chromaprint.overrideAttrs` from a mingw overlay.
{ lib }:
pkgs:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isMinGW  = pkgs.stdenv.hostPlatform.isMinGW or false;
in
(pkgs.chromaprint.override {
  withTools = false;
  withExamples = false;
}).overrideAttrs (oa: {
  buildInputs = [ ];
  propagatedBuildInputs = lib.optionals isMinGW [
    pkgs.windows.mcfgthreads
    pkgs.windows.mcfgthreads.out
  ];
  postInstall = (oa.postInstall or "") + ''
    echo 'Libs.private: ${
      if isDarwin then "-lc++ -lm -framework Accelerate"
      else if isMinGW then "-lstdc++ -lm -lmcfgthread"
      else "-lstdc++ -lm"
    }' \
      >> $out/lib/pkgconfig/libchromaprint.pc
  '' + lib.optionalString isMinGW ''
    sed -i 's|^Cflags: |Cflags: -DCHROMAPRINT_NODLL |' \
      $out/lib/pkgconfig/libchromaprint.pc
  '';
})
