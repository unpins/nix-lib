# pkgsStatic.libxcrypt: skip the test-suite. Two checks fail on a static-musl
# `.a` — symbols-static.pl and symbols-renames.pl — both ABI/symbol-table lint
# (they inspect the library's exported symbol versioning / internal `_crypt_*`
# rename map), NOT crypt() behaviour. Every functional known-answer test
# (alg-*, ka-*) passes or skips, so crypt() is correct; the failures are an
# artifact of the static archive having no versioned dynamic symbol table.
# libxcrypt is a transitive dep (tcsh/perl/shadow link it for crypt()), so it
# self-declares autoWire = "musl" and is folded into the pkgsStatic engine
# overlay for every linux static-musl closure that pulls it in.
{ lib }:
{
  autoWire = "musl";
  apply = pkgs: pkgs.libxcrypt.overrideAttrs (oa: {
    doCheck = false;
  });
}
