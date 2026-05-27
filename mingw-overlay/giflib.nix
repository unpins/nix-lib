# giflib on mingw: the Makefile's `install-lib` target unconditionally
# installs both `libgif.a` AND `libgif.dll.a`. nixpkgs already patches
# the package to add the import-lib line for mingw — but when we build
# under `mingwStaticCross`, the static-libs adapter forces `make` to
# build only the static archive, so `libgif.dll.a` is never produced.
# Install then aborts on the missing import lib.
#
# Drop the import-lib install line via sed; the .a we built is what
# consumers (libwebp, librsvg, gdk-pixbuf, ffmpeg's `--enable-gif`)
# actually link.
{ lib }:
self: super:
super.giflib.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    sed -i '/libgif\.dll\.a/d' Makefile
  '';
})
