# armv7l only: libtheora's 32-bit kernels are hand-written ARM assembly in
# pre-UAL syntax, which GNU as still accepts but clang's integrated assembler
# does not — and the engine has no standalone `as` to fall back on (clang
# assembles internally, so its bintools wrapper ships ar/ld/nm/strip but no
# assembler, and there is nothing for `-no-integrated-as` to reach). Two
# constructs, both pure spelling: same instructions, same encodings.
#
# 1. Condition code before the operand-size suffix: `LDRHIB` / `LDRLOB` instead
#    of UAL's `LDRBHI` / `LDRBLO` ("invalid instruction, did you mean: ldrb,
#    ldrh?"). Nine of them, all in armbits.s; `--replace-fail` asserts they are
#    still there.
#
# 2. `LDRD`/`STRD` naming only the first register of the pair, the second being
#    implicitly Rn+1 ("invalid operand for instruction", or "invalid
#    instruction" when the address is a literal label rather than `[...]`). UAL
#    spells both. All 91 of them across armfrag/armidct/armloop are the old
#    form, over five even-start registers, so this one is a regex — followed by
#    a grep asserting none survived, which is the real check either way.
#
# No data-processing mnemonic in the tree has the pre-UAL `<cond>S` order, so
# those two are the whole of it. Only aarch32 has these sources at all.
{ lib }:
{
  autoWire = "musl";
  apply = scope: scope.libtheora.overrideAttrs (oa:
    lib.optionalAttrs scope.stdenv.hostPlatform.isAarch32 {
      postPatch = (oa.postPatch or "") + ''
        substituteInPlace lib/arm/armbits.s \
          --replace-fail 'LDRHIB' 'LDRBHI' \
          --replace-fail 'LDRLOB' 'LDRBLO'

        # The `[^r[:space:]]` guard is what makes this a no-op on an operand
        # that already names the pair — the address is either `[` or a literal
        # label, never a register.
        sed -i -E \
          -e 's/\b(LDRD|STRD)([[:space:]]+)r2,([[:space:]]*)([^r[:space:]])/\1\2r2, r3,\3\4/' \
          -e 's/\b(LDRD|STRD)([[:space:]]+)r4,([[:space:]]*)([^r[:space:]])/\1\2r4, r5,\3\4/' \
          -e 's/\b(LDRD|STRD)([[:space:]]+)r6,([[:space:]]*)([^r[:space:]])/\1\2r6, r7,\3\4/' \
          -e 's/\b(LDRD|STRD)([[:space:]]+)r8,([[:space:]]*)([^r[:space:]])/\1\2r8, r9,\3\4/' \
          -e 's/\b(LDRD|STRD)([[:space:]]+)r10,([[:space:]]*)([^r[:space:]])/\1\2r10, r11,\3\4/' \
          lib/arm/armfrag.s lib/arm/armidct.s lib/arm/armloop.s
        if grep -nE '\b(LDRD|STRD)[[:space:]]+r[0-9]+,[[:space:]]*[^r[:space:]]' lib/arm/*.s; then
          echo "libtheora: pre-UAL LDRD/STRD survived the rewrite (see above)" >&2
          exit 1
        fi
      '';
    });
}
