# armv7l under the engine: libde265/arm/CMakeLists.txt passes `-DHAVE_AS_FUNC`
# unconditionally — it never probes for it — so asm.S emits `.func`/`.endfunc`
# around every NEON routine. Those are GNU-as debug annotations that clang's
# integrated assembler does not implement (`error: unknown directive`), and the
# engine has no standalone `as` to fall back to (see the libvpx/libtheora cases).
# The macro is upstream's own escape hatch: with it undefined, asm.S comments the
# two directives out and emits identical code, so the NEON kernels stay on.
#
# Auto-wired: libde265 arrives transitively through libheif, so a consumer that
# fixes it by hand only reaches the copy IT names — same reasoning as
# native-overlay/graphite2.nix. Identity off engine-aarch32.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    let
      isEngine = lib.isUnpinEngine pkgs;
    in
    if isEngine && pkgs.stdenv.hostPlatform.isAarch32 then
      pkgs.libde265.overrideAttrs
        (oa: {
          postPatch = (oa.postPatch or "") + ''
            substituteInPlace libde265/arm/CMakeLists.txt \
              --replace-fail '-DHAVE_AS_FUNC' ""
          '';
        })
    else
      pkgs.libde265;
}
