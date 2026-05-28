# nixpkgs `pkgsStatic.rubberband` pulls `vamp-plugin-sdk` + `lv2` +
# `ladspa-header` + `jdk_headless` as build inputs because the
# upstream Makefile *emits* a Vamp plugin / LADSPA plugin / LV2
# plugin / Java JNI binding as side-targets. The core
# `librubberband.a` doesn't consume any of them at link time —
# they're separate `.so` outputs the build produces from the same
# source tree.
#
# In pkgsStatic, the Vamp SDK's Makefile unconditionally links
# `libvamp-sdk.so` (no SHARED-toggle knob), which fails the
# now-familiar `crtbeginT.o R_X86_64_32 against __TMC_END__` —
# static-PIE startup objects refuse shared output. Disabling all
# four side-plugins at meson configure (`-Dvamp=disabled`, …) drops
# every dep we don't need and reduces the chain to `fftw +
# libsamplerate`.
#
# Three extra fixes:
#
# 1. `propagatedBuildInputs` REPLACED (not extended). pkgsStatic
#    auto-promotes upstream `buildInputs` into it, so the unwanted
#    SDKs would stay in the closure if we only extended.
#
# 2. `fftw` swapped for `[[fftw]]` — the upstream fftw drags openmp's
#    broken-python3 chain on darwin. Done at callPackage level so
#    fftw's own evaluation uses the fixed variant; `overrideAttrs`
#    would be too late (the `.eval` of `pkgs.rubberband` already
#    triggers fftw eval).
#
# 3. darwin-aarch64 `cpu_family = 'arm64'` (same meson cross-file
#    mismatch as libopus.nix / dav1d.nix here). meson.build:21 sets
#    `architecture = host_machine.cpu_family()`, which nixpkgs writes
#    as 'arm64' (not 'aarch64'); the darwin arch dispatch only matches
#    `architecture == 'aarch64'`, so it falls through to
#    meson.build:472 `error('Build for architecture arm64 is not
#    supported on this platform')`. Accept 'arm64' at both gates. The
#    only literal 'arm64' use is the `-arch arm64` clang flag *inside*
#    the aarch64 branch (correct for Apple), so this is complete.
#
# `openjdk-headless` is filtered from `nativeBuildInputs` because
# `-Djni=disabled` doesn't remove it from the build environment;
# upstream wires the JNI binding under `with-jni` Makefile target
# whose recipe still calls `javac` even when meson disables it.
#
# On mingw, the splicing of `jdk_headless` resolves to `zulu`,
# which is marked `meta.unsupported` for `x86_64-windows` — eval
# fails *before* the post-hoc nativeBuildInputs filter can run.
# Override `jdk_headless = pkgs.emptyDirectory` at callPackage
# level so eval succeeds; the filter then drops the placeholder
# from nativeBuildInputs at build time on every platform.
{ lib }:
pkgs:
let
  fftwFixed = lib.nativeFixes.fftw pkgs;
in
(pkgs.rubberband.override {
  # callPackage-level fftw swap so `buildInputs = [...fftw...]`
  # inside rubberband's package.nix resolves to our fixed fftw
  # (on darwin: openmp-free to dodge the python3-broken chain —
  # see [[fftw]] / [[llvm-openmp]]). overrideAttrs would be too
  # late; eval of `pkgs.rubberband` already triggers fftw eval.
  fftw = fftwFixed;
  # mingw eval-time bypass; harmless on linux/darwin (filtered
  # out below anyway).
  jdk_headless = pkgs.emptyDirectory;
}).overrideAttrs (oa: {
  # See fix #3 above — both arch gates are `architecture == 'aarch64'`.
  postPatch = (oa.postPatch or "") + ''
    substituteInPlace meson.build \
      --replace-fail "architecture == 'aarch64'" \
                     "architecture in ['aarch64', 'arm64']"
  '';
  nativeBuildInputs = builtins.filter
    (d:
      let p = d.pname or null; in
      p != "openjdk-headless" && p != "empty-directory")
    (oa.nativeBuildInputs or [ ]);
  buildInputs = [ fftwFixed pkgs.libsamplerate ];
  propagatedBuildInputs = [ fftwFixed pkgs.libsamplerate ];
  mesonFlags = (oa.mesonFlags or [ ]) ++ [
    "-Dvamp=disabled"
    "-Dladspa=disabled"
    "-Dlv2=disabled"
    "-Djni=disabled"
    "-Dcmdline=disabled"
    "-Dtests=disabled"
    "-Dfft=fftw"
    "-Dresampler=libsamplerate"
  ];
})
