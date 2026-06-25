# pkgsStatic.xvidcore: build & install only the static lib. The Makefile's
# `all` also builds `libxvidcore.so.4.3` with no `--disable-shared` knob, and
# the `.so` link fails (`crtbeginT.o R_X86_64_32 against __TMC_END__`). Pass
# the `.a` as a makeFlag to reduce `all` to the archive, then install by hand
# (upstream `make install` needs the `.so`).
#
# MinGW quirk: `platform.inc` names the archive `xvidcore.a` (no `lib`
# prefix), vs `libxvidcore.a` elsewhere — so the makeFlag follows configure,
# but install always lands as `libxvidcore.a` so `-lxvidcore` resolves.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  staticLib = if isMinGW then "xvidcore.a" else "libxvidcore.a";
in
pkgs.xvidcore.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ staticLib ];
  installPhase = ''
    runHook preInstall
    install -Dm644 =build/${staticLib} $out/lib/libxvidcore.a
    install -Dm644 ../../src/xvid.h $out/include/xvid.h
    runHook postInstall
  '';
  postInstall = "";
})
