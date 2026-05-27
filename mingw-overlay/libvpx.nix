# libvpx cross-mingw, four fixes:
#
# 1. `examplesSupport = false` override. The examples (`vpxenc`,
#    `vpxdec`) don't link under the mingwStaticCross adapter's
#    `-all-static`; killing them keeps the lib build clean.
#    Consequence: drop the `bin` output (otherwise fixupPhase
#    errors on the empty `bin/`).
#
# 2. Rewrite `--target=` configureFlag. nixpkgs derives the libvpx
#    target as `<cpu>-${kernel.name}-gcc` = `x86_64-windows-gcc`,
#    which libvpx's `all_platforms` doesn't recognise. The valid
#    name is `x86_64-win64-gcc`. Also drop `--enable-shared`.
#
# 3. `export CROSS=<triple>-`. libvpx's configure resolves the
#    target to bare `gcc`/`ld`/`ar` and prepends `${CROSS}`. Without
#    CROSS, configure runs the BUILD-platform gcc and the link
#    probe fails ("Toolchain is unable to link executables" — the
#    build-gcc can't emit COFF for win64).
#
# 4. `+ windows.pthreads`. Upstream nixpkgs hard-codes
#    `NIX_LDFLAGS = [ "-lpthread" ]` to placate the configure link
#    probe; on mingw, winpthreads provides `libpthread.a`.
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
