# nixpkgs x265 in pkgsStatic needs three surgical patches:
#
#  1. Multi-bit-depth archives stay separate. With the default
#     `multibitdepthSupport = true`, the build produces three archives
#     — main (8-bit), `libx265-10.a` (Main10/HDR10), `libx265-12.a`
#     (Main12) — and the main archive references `x265_10bit::` /
#     `x265_12bit::` symbols from the siblings. The dynamic-lib build
#     merges them into one `.so`; pkgsStatic suppresses the `.so` and
#     leaves the static archives unmerged, so any consumer linking
#     `-lx265` sees undefined references. Merge the three with `ar -M`
#     into a self-contained `libx265.a` (postBuild). Cutting
#     `multibitdepthSupport` instead would drop HDR10/Main12 — too
#     much loss for a static-lib rebundle.
#
#  2. `rm -f $out/lib/*.a` in upstream postInstall — correct for the
#     dynamic default, fatal for pkgsStatic. Replace with empty.
#
#  3. mingw-only: x265's CMake probes the toolchain at configure time
#     for "what runtime libs does C++ EH need" and embeds the captured
#     flags in `x265.pc` as `Libs.private`. The probe runs WITHOUT
#     `-static-libgcc`, so it captures the dynamic-libgcc spec:
#       Libs.private: -lstdc++ -lgcc_s -lgcc -lmcfgthread -lntdll ...
#     Any consumer running `pkg-config --static --libs x265` (ffmpeg's
#     link does) then re-injects `-lgcc_s`, and the linker prefers
#     `libgcc_s.dll.a` (an import lib for `libgcc_s_seh-1.dll`) over
#     the static unwind in `libgcc_eh.a`. Result: the .exe imports
#     `libgcc_s_seh-1.dll` (and transitively `libmcfgthread-2.dll`)
#     even though we pass `-static -static-libgcc -static-libstdc++`.
#     Rewrite `Libs.private` to the static-libgcc form via postFixup
#     (postInstall is forced empty above, so this has to live in a
#     later phase).
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.x265.overrideAttrs (oa: {
  postBuild = (oa.postBuild or "") + ''
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
  '';
  postInstall = "";
  postFixup = (oa.postFixup or "") + lib.optionalString isMinGW ''
    for pc in $out/lib/pkgconfig/x265.pc $dev/lib/pkgconfig/x265.pc; do
      [ -f "$pc" ] || continue
      sed -i \
        -e 's|^\(Libs.private:\).*|\1 -lstdc++ -lgcc -lgcc_eh -lmcfgthread -lntdll|' \
        "$pc"
    done
  '';
})
