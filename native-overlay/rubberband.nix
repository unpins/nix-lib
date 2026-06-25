# nixpkgs `pkgsStatic.rubberband` pulls `vamp-plugin-sdk` + `lv2` +
# `ladspa-header` + `jdk_headless` only for side-target plugins; the core
# `librubberband.a` links none of them. The Vamp SDK's `libvamp-sdk.so` also
# fails the static link (`crtbeginT.o R_X86_64_32 against __TMC_END__`).
# Disabling all four side-plugins at meson configure drops the deps and
# reduces the chain to `fftw + libsamplerate`. Extra fixes:
#
# 1. `propagatedBuildInputs` REPLACED, not extended — pkgsStatic auto-promotes
#    upstream `buildInputs` into it, so extending would keep the SDKs.
#
# 2. `fftw` swapped for the fixed `[[fftw]]` (upstream drags openmp's
#    broken-python3 chain on darwin). At callPackage level — overrideAttrs is
#    too late, eval of `pkgs.rubberband` already triggers fftw eval.
#
# 3. darwin-aarch64: meson.build writes `cpu_family = 'arm64'` but the arch
#    dispatch matches only `'aarch64'` → `error('… architecture arm64 …')`.
#    Accept both gates. (The `-arch arm64` clang flag is correct as-is.)
#
# `openjdk-headless` is filtered from `nativeBuildInputs`: `-Djni=disabled`
# doesn't remove it (the `with-jni` recipe still calls `javac`). On mingw,
# `jdk_headless` splices to `zulu` (`meta.unsupported` on x86_64-windows) →
# eval fails before the filter runs, so override it to `emptyDirectory` at
# callPackage level; the filter then drops the placeholder everywhere.
{ lib }:
pkgs:
let
  fftwFixed = lib.nativeFixes.fftw pkgs;
in
(pkgs.rubberband.override {
  fftw = fftwFixed; # see header #2
  jdk_headless = pkgs.emptyDirectory; # mingw eval bypass; see header
}).overrideAttrs (oa: {
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
