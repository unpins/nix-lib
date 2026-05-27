# nixpkgs xvidcore's Makefile builds both `libxvidcore.a` AND
# `libxvidcore.so.4.3` unconditionally — the `all` goal makes both,
# and there is no `--disable-shared` knob. pkgsStatic toolchain fails
# the `.so` link with `R_X86_64_32 against hidden symbol __TMC_END__`
# — static-PIE startup objects (`crtbeginT.o`) can't go into a shared
# object.
#
# Build only the static target. `make install` wants the `.so` we
# didn't build, so skip it; install the `.a` + header by hand. xvid's
# build emits the archive into a literal directory named `=build/`
# inside `build/generic/`.
#
# On mingw the platform.inc emits `STATIC_LIB = xvidcore.a` (without
# the `lib` prefix) and `SHARED_LIB = xvidcore.dll`. Use the
# platform-appropriate filename so the makeFlag + install lines line
# up with what configure actually generates.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  staticLib = if isMinGW then "xvidcore.a" else "libxvidcore.a";
in
pkgs.xvidcore.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ staticLib ];
  # Always install as `libxvidcore.a` so consumers' `-lxvidcore`
  # resolves under standard ld search rules — mingw doesn't look up
  # bare `xvidcore.a` from `-l`.
  installPhase = ''
    runHook preInstall
    install -Dm644 =build/${staticLib} $out/lib/libxvidcore.a
    install -Dm644 ../../src/xvid.h $out/include/xvid.h
    runHook postInstall
  '';
  postInstall = "";
})
