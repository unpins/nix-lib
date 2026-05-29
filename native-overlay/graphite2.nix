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
#
# Second, static-only (any platform): CMake's libtool-emulation writes a
# `libgraphite2.la` with `old_library=''` and `library_names='libgraphite2.so
# ...'` even though only the static archive was built. A libtool consumer
# (chafa is autotools) reads it, can't find the `.so`, and has no static
# fallback — `cannot find .../libgraphite2.so`. Rewrite the `.la` to name the
# static archive and drop the phantom shared names. pkg-config consumers
# (ffmpeg) never read the `.la`, so they don't trip this.
{ lib }:
pkgs:
let
  host = pkgs.stdenv.hostPlatform;
in
pkgs.graphite2.overrideAttrs (oa:
  (lib.optionalAttrs host.isDarwin {
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
  // (lib.optionalAttrs host.isStatic {
    postFixup = (oa.postFixup or "") + ''
      la="$out/lib/libgraphite2.la"
      if [ -f "$la" ]; then
        sed -i \
          -e "s|^old_library=.*|old_library='libgraphite2.a'|" \
          -e "s|^dlname=.*|dlname=|" \
          -e "s|^library_names=.*|library_names=|" \
          "$la"
      fi
    '';
  })
)
