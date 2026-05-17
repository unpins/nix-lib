# links2 via mkPkgsCosmo for Windows-x86_64.
#
# nixpkgs' links2 defaults to graphics mode and pulls
# libpng/libjpeg/libtiff/libavif/librsvg/libev/gpm. We ship text-only,
# so drop the graphics chain via enableX11/enableFB=false plus a full
# buildInputs override (pkgsStatic auto-promotes buildInputs into
# propagatedBuildInputs, so overriding only buildInputs leaves the
# graphics libs in the closure — strip propagated too).
#
# --without-libevent makes links use plain select(); cosmo libc
# translates select() to WSAPoll+WaitForMultipleObjects under the hood
# so the existing event loop "just works" on Windows (mingw select()
# only accepts SOCKET handles, which is why the pure-mingw cross at
# playground/links was a dead end).
#
# Patch default.c so the bundled Mozilla CA bundle (certs.inc) is on
# by default — upstream only enables this on DOS/OPENVMS, but our
# Windows binary has no system CA store path baked in (OPENSSLDIR
# resolves to /build/cosmos/etc/ssl which doesn't exist at runtime)
# and asking users for `-ssl.builtin-certificates 1` every invocation
# would be a footgun.
#
# apelink ELF -> PE32+ in postFixup, mirroring cosmo/dash.nix.
{ lib }:
final: prev:
let
  cs = import ../cosmocc.nix { pkgs = final.buildPackages; };
in
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  links2 = (prev.links2.override {
    enableX11 = false;
    enableFB = false;
  }).overrideAttrs (oa: {
    buildInputs = with final; [ openssl zlib bzip2 xz ];
    propagatedBuildInputs = with final; [ openssl zlib bzip2 xz ];
    configureFlags = (oa.configureFlags or [ ]) ++ [
      "--disable-graphics"
      "--without-x"
      "--without-libevent"
      "--without-brotli"
      "--without-zstd"
      "--enable-utf8"
      "--enable-debuglevel=0"
    ];
    postPatch = (oa.postPatch or "") + ''
      substituteInPlace default.c \
        --replace-fail \
          '#if defined(DOS) || defined(OPENVMS)' \
          '#if defined(DOS) || defined(OPENVMS) || defined(__COSMOPOLITAN__)'
    '';
    postFixup = (oa.postFixup or "") + ''
      ${cs.cosmocc}/bin/apelink \
        -V ${toString cs.platformBits.windows} \
        -o $out/bin/links.exe \
        $out/bin/links
      rm -f $out/bin/links
    '';
  });
} else { }
