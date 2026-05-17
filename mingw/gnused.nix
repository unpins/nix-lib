# sed's bundled gnulib has `getrandom.c` that calls `BCryptGenRandom` on
# _WIN32 but configure's gl_LIBS_LIB_RANDOM probe doesn't pick up `-lbcrypt`
# under cross. Add it explicitly to LIBS; everything else cross-builds clean.
{ lib }:
pkgs:
let cross = lib.mingwStaticCross pkgs; in
cross.gnused.overrideAttrs (old: {
  NIX_LDFLAGS = (old.NIX_LDFLAGS or "") + " -lbcrypt";
})
