# tree's Makefile defaults `LDFLAGS?=-s`, stripping at link time, but cosmocc's
# apelink needs the ELF .symtab for the APE entry points ("missing elf symbol
# table"). Override with `LDFLAGS=`; nixpkgs' stripPhase strips after apelink.
{ lib }:
final: prev:
prev.tree.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "LDFLAGS=" ];
})
