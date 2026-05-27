# libdatrie on mingw: install creates a `bin/trietool-0.2 ->
# bin/trietool` symlink, but the real binary on Windows is
# `trietool.exe`. nixpkgs' `noBrokenSymlinks` fixup check fires
# at the end of the build and aborts with "the symlink
# trietool-0.2 points to a missing target".
#
# Rather than re-pointing the symlink at `trietool.exe` (fragile
# — install phases re-create it and our postInstall ordering is
# ambiguous), run the fix in `preFixup` (after install, before
# the symlink check) and replace the dangling link with a
# proper one to the `.exe`.
{ lib }:
self: super:
super.libdatrie.overrideAttrs (old: {
  preFixup = (old.preFixup or "") + ''
    if [ -L "$bin/bin/trietool-0.2" ] && [ ! -e "$bin/bin/trietool-0.2" ]; then
      rm "$bin/bin/trietool-0.2"
      ln -s trietool.exe "$bin/bin/trietool-0.2"
    fi
  '';
})
