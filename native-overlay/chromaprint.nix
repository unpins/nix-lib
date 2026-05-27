# pkgsStatic.chromaprint, four fixes:
#
# 1. `withTools = false; withExamples = false`. Upstream pulls
#    `ffmpeg-headless` into buildInputs only for the `fpcalc` CLI
#    (decodes audio before fingerprinting). The lib itself never
#    references libav*. In pkgsStatic the tool would force a
#    circular dep (consumer ffmpeg → chromaprint → ffmpeg-headless)
#    and pull `libpulseaudio` (badPlatforms.isStatic on musl).
#
# 2. `buildInputs = [ ]`; on mingw `propagatedBuildInputs +=
#    windows.mcfgthreads`. After dropping the CLI the core lib has
#    no runtime deps (upstream's `zlib` propagation was for
#    `fpcalc`). MinGW needs mcfgthread propagated because libstdc++
#    refs `_MCF_*` (nixpkgs' mingw gcc is `--enable-threads=mcf`).
#    Propagate both `.dev` (has the `.pc`) and `.out` (has
#    `libmcfgthread.a`) — bare reference only catches `.dev` via
#    splicing.
#
# 3. `.pc Libs.private` append. `libchromaprint.a` is C++
#    (`src/*.cpp`), so static link probes fail with `__cxa_*`/
#    `cosf` undef. Darwin selects `FFT_LIB=vdsp` → archive also
#    references Apple's Accelerate framework.
#
# 4. MinGW only: `.pc Cflags += -DCHROMAPRINT_NODLL`. Header
#    decorates `CHROMAPRINT_API` with `__declspec(dllimport)` on
#    `_WIN32` unless this macro is defined, so static consumers
#    emit `__imp_chromaprint_*` refs the `.a`'s plain symbols
#    can't satisfy. See [[mingw-dllimport-static-pattern]].
#
# Note: split into mingw-overlay/ doesn't work here — the
# `withTools = false` override-arg path re-invokes chromaprint's
# function, dropping any `super.chromaprint.overrideAttrs` set by
# the mingw overlay. Keep mingw fixes inline.
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
