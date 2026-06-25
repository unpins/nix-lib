# libvpx cross-mingw, four fixes:
#
# 1. `examplesSupport = false`. ffmpeg consumes only libvpx.a, so the
#    CLI examples are dead weight; dropping them also avoids the empty
#    `bin/` fixupPhase error. (They DO link on mingw — `unpins/libvpx`
#    re-enables them for a single .exe.)
#
# 2. Rewrite `--target=`. nixpkgs derives `x86_64-windows-gcc`, which
#    libvpx's `all_platforms` doesn't recognise; valid is
#    `x86_64-win64-gcc`. Also drop `--enable-shared`.
#
# 3. `export CROSS=<triple>-`. configure prepends `${CROSS}` to bare
#    `gcc`/`ld`/`ar`; without it, the BUILD gcc runs and the link
#    probe fails (can't emit COFF for win64).
#
# 4. `+ windows.pthreads`. nixpkgs hard-codes `NIX_LDFLAGS=-lpthread`
#    for the configure probe; on mingw winpthreads provides it.
{ lib }:
self: super:
(super.libvpx.override {
  examplesSupport = false;
}).overrideAttrs (oa: {
  configureFlags =
    (builtins.filter
      (f: !(lib.hasPrefix "--target=" f
        || lib.hasPrefix "--enable-shared" f))
      oa.configureFlags)
    ++ [
      "--target=${
        if self.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"
      }-win64-gcc"
      "--enable-static" "--disable-shared"
    ];
  preConfigure = (oa.preConfigure or "") + ''
    export CROSS=${self.stdenv.hostPlatform.config}-
  '';
  buildInputs = (oa.buildInputs or [ ]) ++ [ self.windows.pthreads ];
  outputs = [ "out" "dev" ];
  postInstall = "";
})
