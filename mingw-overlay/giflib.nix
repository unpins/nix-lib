# giflib on mingw: `install-lib` installs both `libgif.a` and
# `libgif.dll.a`, but under `mingwStaticCross` the static-libs adapter
# never builds the import lib → install aborts on the missing file.
# Drop the import-lib install line.
{ lib }:
self: super:
super.giflib.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    sed -i '/libgif\.dll\.a/d' Makefile
  '';
})
