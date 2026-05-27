# `graphite2` 1.3.14 `src/CMakeLists.txt` has two parallel platform branches.
# The Linux branch wraps the post-link `nolib_test` check in
#   if (BUILD_SHARED_LIBS) nolib_test(...) endif ()
# because `$<TARGET_SONAME_FILE:graphite2>` is only valid for shared targets
# (CMake rejects it for STATIC). The Darwin branch (line 148) forgets the
# guard, so static builds abort with
#   CMake Error at Graphite.cmake:6 (add_test):
#     Error evaluating generator expression: $<TARGET_SONAME_FILE:graphite2>
#     TARGET_SONAME_FILE is allowed only for SHARED libraries.
#
# Mirror the Linux guard onto the Darwin branch. `nolib_test` is a
# build-time check, not a build product — guarding it changes nothing in
# the installed library.
{ lib }:
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin then
  pkgs.graphite2.overrideAttrs (oa: {
    postPatch = (oa.postPatch or "") + ''
      substituteInPlace src/CMakeLists.txt --replace-fail \
        '    include(Graphite)
          nolib_test(stdc++ $<TARGET_SONAME_FILE:graphite2>)' \
        '    include(Graphite)
          if (BUILD_SHARED_LIBS)
              nolib_test(stdc++ $<TARGET_SONAME_FILE:graphite2>)
          endif ()'
    '';
  })
else
  pkgs.graphite2
