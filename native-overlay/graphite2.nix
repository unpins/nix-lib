# Two fixes, for every engine platform.
#
# First, engine (any OS): the root CMakeLists unconditionally builds the
# `tests/` (examples + featuremap) and `gr2fonttest` EXECUTABLES, which the
# engine links with an explicit `-lgcc`; the engine uses compiler-rt and ships
# no `libgcc.a`, so `ld.lld: unable to find library -lgcc`. `libgraphite2.a`
# (the only thing harfbuzz needs) builds fine — drop the two executable
# subdirectories. Gated on the engine cc so a non-engine build is byte-identical.
#
# Second, 1.3.15's recipe puts `(python3.withPackages …)` in
# nativeBuildInputs. `withPackages` on the spliced `python3` returns the
# HOST python's env, so a static build asks for a static CPython plus
# fonttools — built with the engine on linux, and on darwin one nixpkgs marks
# broken, so chafa and ffmpeg stopped evaluating there. Hand it the build
# machine's python; the scripts only run at build time.
#
# (1.3.15 itself fixed the two static-build bugs this entry used to carry:
# the darwin `nolib_test` on a SONAME the static build never makes, and a
# `libgraphite2.la` naming a `.so` — both are now inside `BUILD_SHARED_LIBS`.)
#
# Auto-wired: harfbuzz pulls graphite2 transitively, so a consumer that fixes it
# by hand only reaches the copy IT names — the one harfbuzz resolves from the
# unextended scope stays broken. `autoWire = "static"` folds it into the engine
# scope itself, covering linux-musl-static and darwin-static alike;
# `nativeFixes.graphite2` still normalizes to the plain `pkgs: drv` function for
# direct callers.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    let
      isEngine = lib.isUnpinEngine pkgs;
    in
    (pkgs.graphite2.override { python3 = pkgs.buildPackages.python3; }).overrideAttrs (oa: {
      postPatch = (oa.postPatch or "")
        + lib.optionalString isEngine ''
        substituteInPlace CMakeLists.txt \
          --replace-fail 'add_subdirectory(tests)' '# add_subdirectory(tests)' \
          --replace-fail 'add_subdirectory(gr2fonttest)' '# add_subdirectory(gr2fonttest)'
      '';
    });
}
