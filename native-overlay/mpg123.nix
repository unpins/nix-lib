# nixpkgs `mpg123` defaults `withPulse = true` on Linux, pulling
# `libpulseaudio` which is `badPlatforms.isStatic` (dynamic-load-only on musl).
# `libOnly = true` drops the CLI players + audio backends; we only need the
# `libmpg123` decoder. `withConplay = false` satisfies the matching assertion
# (`withConplay → !libOnly`).
#
# But nixpkgs `libOnly` only drops the audio backends — it STILL compiles the
# mpg123/out123 CLI, and under the engine's whole-program LTO that link dies on
# `undefined symbol: fputs` (out123.c's print_outstr, referenced past the LTO
# internalize). Consumers (libopenmpt, libsndfile) need only libmpg123.a, so
# build lib-only for real: `--disable-components --enable-libmpg123`. With no
# programs the declared `man` output is empty, which nix rejects — `mkdir -p
# $man` keeps it valid. Byte-neutral for a dynamic (non-engine) build too.
{ lib }:
pkgs:
(pkgs.mpg123.override {
  libOnly = true;
  withConplay = false;
}).overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ])
    ++ [ "--disable-components" "--enable-libmpg123" ];
  postInstall = (oa.postInstall or "") + ''
    mkdir -p $man
  '';
})
