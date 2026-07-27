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
#
# Third, engine (any OS): the root CMakeLists unconditionally builds the
# `tests/` (examples + featuremap) and `gr2fonttest` EXECUTABLES, which the
# engine links with an explicit `-lgcc`; the engine uses compiler-rt and ships
# no `libgcc.a`, so `ld.lld: unable to find library -lgcc`. `libgraphite2.a`
# (the only thing harfbuzz needs) builds fine — drop the two executable
# subdirectories. Gated on the engine cc so a non-engine build is byte-identical.
#
# Auto-wired: harfbuzz pulls graphite2 transitively, so a consumer that fixes it
# by hand only reaches the copy IT names — the one harfbuzz resolves from the
# unextended scope stays broken, which is how the darwin `nolib_test` abort came
# back. `autoWire = "static"` folds it into the engine scope itself, covering
# linux-musl-static and darwin-static alike; `nativeFixes.graphite2` still
# normalizes to the plain `pkgs: drv` function for direct callers.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    let
      host = pkgs.stdenv.hostPlatform;
      isEngine = lib.hasInfix "unpin-cc" (pkgs.stdenv.cc.name or "");
    in
    pkgs.graphite2.overrideAttrs (oa: {
      postPatch = (oa.postPatch or "")
        + lib.optionalString host.isDarwin ''
          substituteInPlace src/CMakeLists.txt --replace-fail \
            '    include(Graphite)
              nolib_test(stdc++ $<TARGET_SONAME_FILE:graphite2>)' \
            '    include(Graphite)
              if (BUILD_SHARED_LIBS)
                  nolib_test(stdc++ $<TARGET_SONAME_FILE:graphite2>)
              endif ()'
        ''
        + lib.optionalString isEngine ''
          substituteInPlace CMakeLists.txt \
            --replace-fail 'add_subdirectory(tests)' '# add_subdirectory(tests)' \
            --replace-fail 'add_subdirectory(gr2fonttest)' '# add_subdirectory(gr2fonttest)'
        '';
    } // lib.optionalAttrs host.isStatic {
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
    });
}
