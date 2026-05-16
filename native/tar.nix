# GNU tar (gnutar) forks to external gzip/xz/bzip2/zstd binaries via
# compress.c — incompatible with single-binary shipping. libarchive's
# bsdtar links zlib/liblzma/libbz2/libzstd as libraries and handles every
# format in-process. Ship bsdtar renamed to `tar`; drop the other utils
# libarchive installs (bsdcat/bsdcpio/bsdunzip) so the package stays
# one binary.
{ lib }:
pkgs:
pkgs.pkgsStatic.libarchive.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    mv "$out/bin/bsdtar" "$out/bin/tar"
    find "$out/bin" -type f -not -name tar -delete
  '';
})
