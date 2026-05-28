# x265 in pkgsStatic needs four surgical patches:
#
# 1. With `multibitdepthSupport = true`, the build emits three
#    separate archives — 8-bit main + `libx265-10.a` (Main10/HDR10)
#    + `libx265-12.a` (Main12) — and the main references symbols
#    from the siblings. Dynamic builds merge them into one `.so`;
#    pkgsStatic doesn't, so any `-lx265` consumer sees undef refs.
#    Merge via `ar -M` (postBuild) into a unified `libx265.a`.
#    Dropping multibitdepthSupport would shed HDR10/Main12 — too
#    much loss for a static rebundle.
#
#    nixpkgs gates multibitdepth off on aarch64-linux
#    (`is64bit && !(isAarch64 && isLinux)`), so the siblings are
#    absent there and the main archive is already a complete
#    8-bit-only build (HIGH_BIT_DEPTH=OFF, no sibling refs). Guard
#    the merge on the siblings existing rather than re-deriving the
#    platform predicate — robust if upstream flips the gate, and it
#    skips cleanly on aarch64 where there is nothing to merge.
#
# 2. Upstream `postInstall` does `rm -f $out/lib/*.a` — correct
#    for the dynamic default, fatal for pkgsStatic. Clear it.
#
# 3. `x265.pc Libs.private` bakes an absolute
#    `/nix/store/.../libstdc++.a` (x265 is C++). A `pkg-config
#    --static` consumer (ffmpeg's `check_pkg_config`) routes that
#    absolute path to ldflags *before* the test object, where
#    `-Wl,--as-needed` drops it (nothing references it yet); then
#    `-lx265` pulls unresolvable libstdc++ refs (operator new,
#    std::ios_base, vtables). Rewrite to `-lstdc++` so the cc-wrapper
#    appends it at the tail, after the object. Same trap and fix as
#    srt — surfaced on aarch64 (x86_64's x265 test referenced fewer
#    C++ symbols), but the `-l` form is correct everywhere. Darwin's
#    `.pc` carries libc++, not libstdc++.a, so the sed is a no-op.
#
# 4. mingw-only: x265's CMake probe captures the dynamic C++ EH
#    link sequence (`-lgcc_s ...`) into `x265.pc Libs.private`,
#    forcing the consumer `.exe` to import `libgcc_s_seh-1.dll`
#    even with `-static-libgcc`. Rewrite `Libs.private` to the
#    static-libgcc form (fully replaces the line, superseding #3 on
#    mingw). Lives in `postFixup` because (2) emptied `postInstall`.
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
