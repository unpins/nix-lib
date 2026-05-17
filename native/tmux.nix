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
#
# All platforms: bake the curated terminfo fallback list into
# ncurses → tmux's outer-terminal rendering works on hosts without
# `/usr/share/terminfo`. Host terminfo still wins when present.
#
# Inject pkg-config into libevent's nativeBuildInputs. nixpkgs' libevent
# forgets it, which is invisible on x86_64/aarch64 because the configure
# fallback probe `cc conftest.c -lssl -lcrypto` resolves on its own. On
# armv7l (ARM 32-bit) OpenSSL 3.x's libcrypto.a needs `__atomic_*_8`
# from libatomic — `libcrypto.pc` declares it in `Libs.private`, but only
# `pkg-config --libs --static openssl` surfaces it; the bare probe fails
# the link with undefined `__atomic_fetch_add_8`. Splicing-aware: pass
# `scope.pkg-config` (not `scope.buildPackages.pkg-config`) so nixpkgs
# picks the cross-correct `<triple>-pkg-config-wrapper`.
{ lib }:
pkgs:
let
  p = pkgs.pkgsStatic;
  ncursesFB = lib.embedFallbackTerminfo p.ncurses;
  libeventFixed = scope: scope.libevent.overrideAttrs (oa: {
    nativeBuildInputs = (oa.nativeBuildInputs or [ ]) ++ [ scope.pkg-config ];
  });
in
if p.stdenv.hostPlatform.isDarwin
then
  ((lib.withDepsSharedPruned pkgs pkgs.tmux).override {
    ncurses = ncursesFB;
    libevent = libeventFixed pkgs;
  }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace configure.ac \
        --replace-fail 'LIBS="$OLD_LIBS -lresolv"' 'LIBS="$OLD_LIBS"'
      substituteInPlace compat/base64.c \
        --replace-fail '#include <resolv.h>' ""
    '';
  })
else
  p.tmux.override {
    ncurses = ncursesFB;
    libevent = libeventFixed p;
  }
