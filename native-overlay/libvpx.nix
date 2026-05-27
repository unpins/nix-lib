# libvpx fixes for darwin and mingw.
#
# Darwin: two issues stack.
# 1. nixpkgs `libvpx` package.nix references the legacy
#    `stdenv.hostPlatform.osxMinVersion`, which was renamed to
#    `darwinMinVersion` in modern nixpkgs systems lib (see
#    `lib/systems/default.nix:364`). The package wasn't updated, so
#    eval crashes on darwin with `attribute 'osxMinVersion' missing`.
#    Bridge the rename by injecting `osxMinVersion` into hostPlatform
#    before package.nix reads it. The value used here is a stand-in
#    purely to make eval succeed; the real deployment target is
#    rewritten via the configureFlags filter below.
#
# 2. With the bridged value libvpx's package.nix maps to at most
#    `darwin14` (macOS 10.10), and libvpx's own configure then injects
#    `-mmacosx-version-min=10.10` into CFLAGS+LDFLAGS — which the
#    macOS 14.4 SDK rejects on calls like `CLOCK_MONOTONIC_RAW`
#    (available 10.12+). libvpx supports up to `darwin25` (macOS 15+);
#    rewrite the configure target to `darwin23` (macOS 14, matching
#    nixpkgs's `darwinMinVersion = "14.0"`) so the SDK availability
#    check passes.
#
# MinGW: nixpkgs derives the target string as
# `<cpu>-${stdenv.hostPlatform.parsed.kernel.name}-gcc`, which on
# mingw yields `x86_64-windows-gcc`. libvpx's own `configure`
# `all_platforms` list doesn't know that name — the valid mingw
# w64 target is `x86_64-win64-gcc`. Configure aborts with
# "Unrecognized toolchain 'x86_64-windows-gcc'". Rewrite the flag
# the same way we rewrite it on darwin. Also force static-only +
# kill the example binaries (vpxdec/vpxenc as `.exe`) so the
# mingwStaticCross adapter's `-all-static` doesn't try to link
# them.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then
  (pkgs.libvpx.override {
    stdenv = pkgs.stdenv // {
      hostPlatform = pkgs.stdenv.hostPlatform // {
        osxMinVersion = "10.10";
      };
    };
  }).overrideAttrs (oa: {
    configureFlags =
      (builtins.filter
        (f: !(lib.hasPrefix "--target=x86_64-darwin" f
          || lib.hasPrefix "--target=arm64-darwin" f
          || lib.hasPrefix "--target=aarch64-darwin" f))
        oa.configureFlags)
      ++ [
        "--target=${
          if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"
        }-darwin23-gcc"
      ];
  })
else if pkgs.stdenv.hostPlatform.isMinGW or false
then
  (pkgs.libvpx.override {
    examplesSupport = false;
  }).overrideAttrs (oa: {
    configureFlags =
      (builtins.filter
        (f: !(lib.hasPrefix "--target=" f
          || lib.hasPrefix "--enable-shared" f))
        oa.configureFlags)
      ++ [
        "--target=${
          if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"
        }-win64-gcc"
        "--enable-static" "--disable-shared"
      ];
    # libvpx's configure resolves `<target>` (e.g. x86_64-win64-gcc)
    # to bare `gcc`/`ld`/`ar` invocations and prepends `${CROSS}` if
    # set. Without CROSS, configure runs the BUILD-platform gcc and
    # the link probe fails ("Toolchain is unable to link executables"
    # because the build-gcc can't emit COFF for the win64 target).
    # Inject the cross prefix from nixpkgs' host platform config.
    preConfigure = (oa.preConfigure or "") + ''
      export CROSS=${pkgs.stdenv.hostPlatform.config}-
    '';
    # Upstream hard-codes `NIX_LDFLAGS = [ "-lpthread" ]` to placate
    # the configure link probe. On mingw libpthread lives under the
    # `windows.pthreads` package (libwinpthread / libpthread.a); add
    # it to buildInputs so the probe resolves `-lpthread`.
    buildInputs = (oa.buildInputs or [ ]) ++ [ pkgs.windows.pthreads ];
    # With examplesSupport=false the build produces no vpxdec/vpxenc
    # binaries, so the `bin` output upstream declares stays empty
    # and fixupPhase errors out. Drop the bin output entirely.
    outputs = [ "out" "dev" ];
    postInstall = "";
  })
else pkgs.libvpx
