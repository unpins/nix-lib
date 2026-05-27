# pkgsStatic.xvidcore, one fix (two-part):
#
# Build & install just the static lib. xvidcore's Makefile builds
# both `libxvidcore.a` AND `libxvidcore.so.4.3` from `all` and has
# no `--disable-shared` knob; the `.so` link fails in pkgsStatic
# with `crtbeginT.o R_X86_64_32 against hidden symbol __TMC_END__`
# (static-PIE startup objects refuse to go into a `.so`). Pass the
# `.a` as an explicit makeFlag so `all` reduces to the archive,
# then install by hand (upstream `make install` requires the `.so`
# we didn't build).
#
# MinGW filename quirk: `platform.inc` emits `STATIC_LIB =
# xvidcore.a` (no `lib` prefix) on mingw, vs `libxvidcore.a` on
# everything else. The makeFlag follows what configure generates;
# install always lands as `libxvidcore.a` so consumer `-lxvidcore`
# resolves under standard ld search rules (mingw's `-l` skips
# bare `xvidcore.a`).
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
