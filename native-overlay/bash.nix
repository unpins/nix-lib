# bash's build-correctness fix (pin CC to the engine wrapper + force the
# build-tool codegen onto gnu17) lives in `lib.unpinBashBuildFix`, drv-level so
# the SAME transform applies to every bash variant. This native-overlay entry is
# the standalone-flake view: it fixes the interactive `scope.bash` that the
# `bash` catalog binary ships. The engine all-deps path applies the same helper
# to `bashNonInteractive` (gnugrep's egrep/fgrep runtime shell). Idempotent, so
# reaching it twice is a no-op. See lib.unpinBashBuildFix for the why.
{ lib }:
scope:
lib.unpinBashBuildFix scope scope.bash
