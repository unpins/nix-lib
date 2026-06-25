# x265 in pkgsStatic needs four surgical patches:
#
# 1. `multibitdepthSupport = true` emits three archives — 8-bit main +
#    `libx265-10.a` + `libx265-12.a` — with the main referencing the siblings.
#    Dynamic builds merge them into one `.so`; pkgsStatic doesn't, so `-lx265`
#    sees undef refs. Merge via `ar -M` (postBuild). nixpkgs gates multibitdepth
#    off on aarch64-linux, so guard the merge on the siblings existing rather
#    than re-deriving the platform predicate.
#
# 2. Upstream `postInstall` `rm -f $out/lib/*.a` is fatal for pkgsStatic. Clear.
#
# 3. `x265.pc Libs.private` bakes an absolute `libstdc++.a`; `pkg-config
#    --static` consumers route it to ldflags before the test object where
#    `--as-needed` drops it → unresolvable libstdc++ refs. Rewrite to
#    `-lstdc++`. Same trap as srt. (Darwin's `.pc` has libc++ → no-op.)
#
# 4. mingw-only: x265's CMake probe bakes the dynamic C++ EH sequence
#    (`-lgcc_s …`) into `Libs.private`, forcing `libgcc_s_seh-1.dll` even with
#    `-static-libgcc`. Rewrite the whole line to static-libgcc form
#    (supersedes #3 on mingw). In `postFixup` since (2) emptied `postInstall`.
#    See [[mingw-pc-libgcc-s-probe-trap]].
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.x265.overrideAttrs (oa: {
  postBuild = (oa.postBuild or "") + ''
    if [ -e libx265-10.a ] && [ -e libx265-12.a ]; then
      echo "merging libx265.a + libx265-10.a + libx265-12.a → unified libx265.a"
      $AR -M <<'EOF'
    CREATE libx265-merged.a
    ADDLIB libx265.a
    ADDLIB libx265-10.a
    ADDLIB libx265-12.a
    SAVE
    END
    EOF
      mv libx265-merged.a libx265.a
    else
      echo "multibitdepth siblings absent (aarch64-linux); skipping merge"
    fi
  '';
  postInstall = "";
  postFixup = (oa.postFixup or "") + ''
    # Fix #3: absolute libstdc++.a → -lstdc++ (no-op on darwin/mingw).
    for pc in $out/lib/pkgconfig/x265.pc $dev/lib/pkgconfig/x265.pc; do
      [ -f "$pc" ] || continue
      sed -i -E 's|[^ ]*/libstdc\+\+\.a|-lstdc++|g' "$pc"
    done
  '' + lib.optionalString isMinGW ''
    for pc in $out/lib/pkgconfig/x265.pc $dev/lib/pkgconfig/x265.pc; do
      [ -f "$pc" ] || continue
      sed -i \
        -e 's|^\(Libs.private:\).*|\1 -lstdc++ -lgcc -lgcc_eh -lmcfgthread -lntdll|' \
        "$pc"
    done
  '';
})
