# libsepol's src/Makefile decides whether the C library already provides
# reallocarray(3) by compiling+linking a probe that pipes a tiny program through
# `$CC ... -x c -o /dev/null -` (source on stdin). The unpin-llvm engine's
# cc-wrapper mishandles that stdin-source / /dev/null-output combo, so the probe
# spuriously fails, HAVE_REALLOCARRAY stays undefined, and private.h falls back to
# its own `static inline reallocarray` — which then collides with the engine's
# zig-musl <stdlib.h> declaration (musl ≥1.2.2 provides it), `-Werror` fatal.
# reallocarray genuinely IS available (the collision proves it's declared, and it
# links), so force HAVE_REALLOCARRAY on; the probe's own conditional append below
# it becomes a harmless no-op. Pulled in transitively (glib → libselinux →
# libsepol, e.g. tmux's libutempter); musl-only since SELinux is Linux-only.
{ lib }:
{
  autoWire = "musl";
  apply = pkgs: pkgs.libsepol.overrideAttrs (oa: {
    postPatch = (oa.postPatch or "") + ''
            substituteInPlace src/Makefile \
              --replace-fail '# check for reallocarray(3) availability' \
                '# check for reallocarray(3) availability
      override CFLAGS += -DHAVE_REALLOCARRAY'
    '';
  });
}
