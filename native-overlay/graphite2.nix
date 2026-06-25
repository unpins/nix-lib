# graphite2 1.3.14's CMakeLists guards the `nolib_test` check
# (`$<TARGET_SONAME_FILE:graphite2>`, valid only for SHARED) in
# `if (BUILD_SHARED_LIBS)` on the Linux branch but forgets it on the Darwin
# branch, so static darwin builds abort. Mirror the guard; nolib_test is a
# build-time check, not a product.
#
# Second, static-only (any platform): CMake's libtool emulation writes a
# `libgraphite2.la` naming `libgraphite2.so` though only the `.a` was built, so
# an autotools consumer (chafa) can't find the `.so`. Rewrite the `.la` to the
# static archive (pkg-config consumers never read it).
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
