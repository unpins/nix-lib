# Standalone-flake view of `lib.unpinBashBuildFix` (the drv-level CC-pin +
# gnu17 codegen fix; see there for the why): fixes the interactive `pkgs.bash`
# the catalog binary ships. Idempotent.
{ lib }:
pkgs:
lib.unpinBashBuildFix pkgs pkgs.bash
