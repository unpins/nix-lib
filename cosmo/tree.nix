# tree's Makefile sets `LDFLAGS?=-s` and links with `$(CC) $(LDFLAGS) -o tree`,
# so the binary leaves the link step already stripped. cosmocc's apelink needs
# the ELF .symtab to find the APE entry points, so we'd fail in the auto-apelink
# fixup hook with "missing elf symbol table". Pass `LDFLAGS=` via makeFlags to
# override the `?=` default; the cc-wrapper still sees an unstripped binary and
# nixpkgs' own stripPhase strips it after apelink has converted ELF → PE32+.
{ lib }:
final: prev:
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  tree = prev.tree.overrideAttrs (oa: {
    makeFlags = (oa.makeFlags or [ ]) ++ [ "LDFLAGS=" ];
  });
} else { }
