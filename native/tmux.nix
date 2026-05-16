# darwin: pkgsStatic.tmux's configure.ac passes `-static` globally → libSystem
# link probe fails. Fall back to regular tmux with deps' shared libs pruned;
# runtime closure ends up libSystem-only either way.
#
# Plus postPatch: tmux's configure.ac probes `b64_ntop` against -lresolv;
# on darwin libresolv provides it so tmux links libresolv.9.dylib. We only
# want libSystem in the binary, so disable that probe — tmux falls back to
# its bundled compat/base64.c.
#
# Second patch: darwin's <resolv.h> macros-rename `b64_ntop` to
# `res_9_b64_ntop`. compat.h `#undef`s these macros at call sites, but
# compat/base64.c (the bundled implementation) still picks them up and
# ends up defining `_res_9_b64_ntop`, leaving `_b64_ntop` undefined.
# Drop the unused `#include <resolv.h>` from compat/base64.c so the
# function names match across translation units.
{ lib }:
pkgs:
let p = pkgs.pkgsStatic; in
if p.stdenv.hostPlatform.isDarwin
then (lib.withDepsSharedPruned pkgs pkgs.tmux).overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace configure.ac \
      --replace-fail 'LIBS="$OLD_LIBS -lresolv"' 'LIBS="$OLD_LIBS"'
    substituteInPlace compat/base64.c \
      --replace-fail '#include <resolv.h>' ""
  '';
})
else p.tmux
