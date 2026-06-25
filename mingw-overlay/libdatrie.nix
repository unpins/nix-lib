# libdatrie on mingw: install makes `trietool-0.2 -> trietool`, but the
# real binary is `trietool.exe` → nixpkgs' `noBrokenSymlinks` check aborts.
# Re-point at the `.exe` in `preFixup` (after install, before the check;
# postInstall ordering vs. install re-creating the link is ambiguous).
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
