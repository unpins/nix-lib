# nixpkgs `pkgsStatic.chromaprint` pulls `ffmpeg-headless` into
# `buildInputs` because of the `fpcalc` CLI binary (decodes audio
# via libav* before fingerprinting). The library itself
# (`libchromaprint.a`) never references libavcodec — decoding is
# the consumer's responsibility. In pkgsStatic this becomes a
# circular dep (consumer ffmpeg → chromaprint → ffmpeg-headless),
# and worse: `ffmpeg-headless` propagates `libpulseaudio`, which
# has `meta.badPlatforms = lib.platforms.isStatic` on musl.
#
# Disable `withTools` + `withExamples` and clear `buildInputs` +
# `propagatedBuildInputs` — the core lib needs no runtime deps.
# (`zlib` is unused by `libchromaprint.a`; the upstream propagation
# was for the CLI.)
#
# Two `.pc` fixups for static consumers calling
# `pkg-config --static chromaprint`:
#
# - `libchromaprint.a` is C++ (`src/*.cpp`). Upstream's
#   `libchromaprint.pc` omits `Libs.private`, so the static link
#   probe fails with `undefined reference to __cxa_*` / `cosf`.
#   Append `-lstdc++ -lm` (libc++ on darwin: clang uses libc++
#   not libstdc++).
#
# - chromaprint's CMake auto-selects `FFT_LIB=vdsp` on darwin →
#   `libchromaprint.a` references vDSP_* symbols from Apple's
#   Accelerate framework. Append `-framework Accelerate` on darwin
#   so consumer link probes resolve those symbols.
#
# - On cross-mingw, `-lstdc++` requires `-lmcfgthread` because
#   nixpkgs' mingw gcc is built with `--enable-threads=mcf`
#   (libstdc++ refs `_MCF_tls_key_new` etc). Without it, consumer
#   link probes (ffmpeg's `check_pkg_config`) fail with "cannot
#   find -lmcfgthread". Add `windows.mcfgthreads` as a propagated
#   buildInput so the `-L<store>/lib` is in PKG_CONFIG/LD search.
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
  # Propagate both `.dev` (has the .pc) and `.out` (has libmcfgthread.a);
  # the bare reference only catches `.dev` via splicing.
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
    # chromaprint.h does `#define CHROMAPRINT_API __declspec(dllimport)`
    # on `_WIN32` unless `CHROMAPRINT_NODLL` is defined. Static
    # consumers must build with `-DCHROMAPRINT_NODLL`, else the
    # compiler emits `__imp_chromaprint_*` refs that can't be
    # satisfied by `libchromaprint.a` (which has plain
    # `chromaprint_*` symbols).
    sed -i 's|^Cflags: |Cflags: -DCHROMAPRINT_NODLL |' \
      $out/lib/pkgconfig/libchromaprint.pc
  '';
})
