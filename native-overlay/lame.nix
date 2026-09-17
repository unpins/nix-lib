# i686 only: lame's configure appends `-march=i686 -mtune=native` to its own
# CFLAGS whenever the compiler is clang. The engine's i386 baseline has SSE2 —
# everything else in a fold is built for it — so lame's objects come out with
# fewer target features than the code they are linked with.
#
# Under whole-program LTO that is an ABI break, not just slower code. LLVM
# inlines lame's featureless `psymodel_init` into an SSE caller and turns the
# internal call to `init_numline` into fastcc; the SSE caller passes the float
# `sfreq` in xmm0, the non-SSE callee reads it from the stack, and every stack
# argument after it is off by four bytes. ffmpeg's `-c:a libmp3lame` crashed on
# every i686 encode reading `scalepos` from 0x3fe80000 — the high word of 0.75.
# The lame and sox binaries survive it only because their inlining happens to
# differ.
#
# Dropping the flags builds lame for the same baseline as the rest of the link.
# `-mtune=native` goes too: it tunes for whatever machine ran the build. Its SSE
# kernels then compile as they do on x86_64, still picked at runtime.
{ lib }:
{
  autoWire = "musl";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isx86_32 then
      pkgs.lame.overrideAttrs (oa: {
        postPatch = (oa.postPatch or "") + ''
          grep -q -- '-march=i686' configure
          sed -i -e 's/ -march=i[4-6]86//g' -e 's/ -march=native//g' \
            -e 's/-mtune=native//g' configure
          if grep -nE -- '-march=(i[4-6]86|native)|-mtune=native' configure; then
            echo "lame: a -march/-mtune override survived (see above)" >&2
            exit 1
          fi
        '';
      })
    else
      pkgs.lame;
}
