# Each sibling is `{ lib }: final: prev: drv` — the cosmo fix for the package it
# is named after. The isCosmo gate is here rather than in each fix: every one of
# them is cosmo-only, and off cosmo the overlay must contribute nothing so
# buildPackages (linux-gnu) keeps its cache hash.
{ lib }:
final: prev:
lib.optionalAttrs (prev.stdenv.hostPlatform.isCosmo or false)
  (builtins.mapAttrs
    (_: fix: fix final prev)
    (lib.importFixDir { dir = ./.; inherit lib; }))
