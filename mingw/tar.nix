# Same shape as native/tar.nix (libarchive's bsdtar renamed to tar).
# Imports stay system-only (bcrypt/KERNEL32/msvcrt); mingwStaticCross's
# stdenv adapter handles --enable-static --disable-shared for libarchive +
# its deps (zlib, xz, bzip2, zstd, openssl, lzo).
{ lib }:
pkgs:
let cross = lib.mingwStaticCross pkgs; in
cross.libarchive.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    mv "$out/bin/bsdtar.exe" "$out/bin/tar.exe"
    find "$out/bin" -type f -not -name "tar.exe" -delete
  '';
})
