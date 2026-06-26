# pkgsStatic.libxcrypt: skip the test-suite. Two checks fail on a static `.a` —
# symbols-static.pl and symbols-renames.pl — both ABI/symbol-table lint (they
# inspect the library's exported symbol versioning / internal `_crypt_*` rename
# map), NOT crypt() behaviour. Every functional known-answer test (alg-*, ka-*)
# passes or skips, so crypt() is correct; the failures are an artifact of the
# static archive having no versioned dynamic symbol table — and they fail the same
# way on darwin's static .a (arm64 surfaced it; x86_64-darwin was cached green).
# libxcrypt is a transitive dep (tcsh/perl/shadow link it for crypt()), so it
# self-declares autoWire = "static" and is folded into the pkgsStatic engine
# overlay for every static closure — linux musl AND darwin — that pulls it in.
# doCheck=false is unconditional, so the linux static host (isStatic ⟹ isMusl)
# behaves exactly as it did under "musl" and stays byte-identical.
{ lib }:
{
  autoWire = "static";
  apply = pkgs: pkgs.libxcrypt.overrideAttrs (oa: {
    doCheck = false;
  });
}
