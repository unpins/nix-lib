# SQLite's src/hwtime.h defines sqlite3Hwtime() with a per-arch inline asm to
# read a cycle counter. The powerpc branch (`defined(__GNUC__) &&
# defined(__ppc__)`) uses the 32-bit register-pair form `mftbu %1 / mftb %L0 /
# mftbu %0`. clang defines __ppc__ on ppc64le too, so that branch is taken, and
# LLVM's assembler rejects the bare `mftb` (`ld.lld: <inline asm>: too few
# operands for instruction`) — the last engine blocker for any ppc64le consumer
# that drags sqlite (glib/fuse → util-linuxMinimal, even with liblastlog2 off,
# sqlite is a dead over-link).
#
# sqlite3Hwtime() is benchmark-only: hwtime.h's own `#else` comment says it is
# "only used for some obscure debugging and analysis configurations, not in any
# deliverable," and that fallback simply `return 0`. So neutralize the powerpc
# asm branch and let it fall through to that harmless stub. The failure is
# powerpc-only (the branch isn't compiled elsewhere), so gate to isPower — every
# other arch returns the identical derivation (byte-neutral no-op), keeping
# published sqlite byte-for-byte. Pulled in transitively (no consumer patches
# sqlite by hand) → autoWire, static set (all cross/static builds are isStatic).
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isPower then
      pkgs.sqlite.overrideAttrs
        (oa: {
          postPatch = (oa.postPatch or "") + ''
            substituteInPlace src/hwtime.h \
              --replace-fail 'defined(__GNUC__) && defined(__ppc__)' \
                'defined(__GNUC__) && defined(__ppc__) && 0'
          '';
        })
    else
      pkgs.sqlite;
}
