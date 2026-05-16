# mingw counterpart of native/xz.nix. Same pruning: keep only `xz.exe` and
# embed the multicall aliases as UNPIN_META.
{ lib }:
pkgs:
let
  cross = lib.mingwStaticCross pkgs;
  pruned = cross.xz.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + "\n" + ''
      for o in $outputs; do
        d="''${!o}"
        [ -d "$d/bin" ] || continue
        find "$d/bin" -mindepth 1 -maxdepth 1 \
          ! -name 'xz' ! -name 'xz.exe' -delete
      done
    '';
  });
in
lib.withAliases pkgs
  {
    # `withAliases` opens `bin/${primary}` to embed UNPIN_META; mingw outputs
    # have `.exe` suffix.
    primary = "xz.exe";
    aliases = [ "unxz" "xzcat" "lzma" "unlzma" "lzcat" ];
  }
  pruned
