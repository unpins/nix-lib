# nixpkgs' postFixup runs `remove-references-to ... $(readlink -f .../libgme.so)`,
# but pkgsStatic has no `.so` → empty readlink → `sed: no input files` → exit 1.
# Drop postFixup; the `.a` carries no build-tool refs to scrub anyway.
#
# `libgme.pc` ships `Libs.private: -lstdc++ -lz` (upstream's CMake hardcodes the
# gcc runtime). Under the engine there is no `libstdc++.a` to find, so a
# `pkg-config --static` consumer gets a token naming a library that does not
# exist. Name what the toolchain actually has. Same table as chromaprint.nix
# and ../mingw-overlay/graphite2.nix.
{ lib }:
pkgs:
let
  onEngine = lib.hasInfix "unpin-cc" (pkgs.stdenv.cc.name or "");
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  cxxRuntime =
    if !onEngine then "-lstdc++"
    else if isDarwin then "-lc++"
    else if isMinGW then "-lc++ -lc++abi -lunwind"
    else "-lc++ -lc++abi";
in
pkgs.game-music-emu.overrideAttrs (oa: {
  postFixup = "";
  postInstall = (oa.postInstall or "") + lib.optionalString onEngine ''
    pc=$out/lib/pkgconfig/libgme.pc
    if [ -f "$pc" ]; then
      sed -i 's|-lstdc++|${cxxRuntime}|g' "$pc"
    fi
  '';
})
