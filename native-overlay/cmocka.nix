# cmocka's own CTest suite segfaults under the engine: `waiter_test_wrap`
# exercises cmocka's `--wrap` function-mocking (test_order_hotdog / test_bad_dish
# SIGSEGV), whose linker-level symbol interposition the engine's whole-program
# LTO doesn't reproduce faithfully. cmocka is a transitive TEST-framework dep
# (librist's test tooling pulls it even with librist's own `-Dtest=false`); its
# self-tests validate cmocka, not our build, and the shipped `libcmocka.a` is
# unaffected. Skip its checkPhase. autoWire "static" folds it into the engine
# pkgsStatic on both linux-musl and darwin (both isStatic).
{ lib }:
{
  autoWire = "static";
  apply = scope: scope.cmocka.overrideAttrs (_: { doCheck = false; });
}
