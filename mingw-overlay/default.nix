# Fixes for the transitive deps consumed inside `mingwStaticCross`. Each
# sibling is `{ lib }: self: super: drv` — an overlay fragment for the package
# it is named after.
{ lib }:
lib.importFixDir { dir = ./.; inherit lib; }
