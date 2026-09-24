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
#    Accelerate framework. The runtime is named per toolchain, not hardcoded to
#    gcc's — see `cxxRuntime` below.
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
  # `-lstdc++` names a library the engine does not ship (LLVM carries libc++),
  # so a consumer reading this `.pc` fails the link outright. Name what the
  # toolchain actually has. mcfgthread rides with gcc's libstdc++, which calls
  # `_MCF_*`; libc++ never does. Same table as ../mingw-overlay/graphite2.nix
  # and x265.nix.
  onEngine = lib.hasInfix "unpin-cc" (pkgs.stdenv.cc.name or "");
  cxxRuntime =
    if isDarwin then "-lc++ -lm -framework Accelerate"
    else if isMinGW then
      (if onEngine then "-lc++ -lc++abi -lunwind -lm" else "-lstdc++ -lm -lmcfgthread")
    else
      (if onEngine then "-lc++ -lc++abi -lm" else "-lstdc++ -lm");
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
    echo 'Libs.private: ${cxxRuntime}' \
      >> $out/lib/pkgconfig/libchromaprint.pc
  '' + lib.optionalString isMinGW
    (lib.withPcCflags "-DCHROMAPRINT_NODLL" "$out/lib/pkgconfig/libchromaprint.pc");
})
