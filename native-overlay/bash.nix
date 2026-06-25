# Standalone-flake view of `lib.unpinBashBuildFix` (the drv-level CC-pin +
# gnu17 codegen fix; see there for the why): fixes the interactive `scope.bash`
# the catalog binary ships. Idempotent.
{ lib }:
scope:
lib.unpinBashBuildFix scope scope.bash
