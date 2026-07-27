# x265 in pkgsStatic needs four surgical patches:
#
# 1. `multibitdepthSupport = true` emits three archives — 8-bit main +
#    `libx265-10.a` + `libx265-12.a` — with the main referencing the siblings
#    (`x265_10bit::x265_api_get_*`, `x265_12bit::…`). Dynamic builds merge them
#    into one `.so`; pkgsStatic doesn't, so `-lx265` sees undef refs. The three
#    archives share member basenames (each is the same sources rebuilt with a
#    different bit-depth namespace: `api.cpp.o`, `analysis.cpp.o`, …), and the
#    engine's `llvm-ar -M ADDLIB` DEDUPLICATES same-named members (GNU ar keeps
#    duplicates) — dropping the 10/12-bit `api.cpp.o` and leaving the namespaced
#    entry points undefined. Extract each archive into its own dir, prefix the
#    10/12-bit members so nothing collides, then re-archive all objects into one
#    `libx265.a`. Works under both llvm-ar and GNU ar. nixpkgs gates
#    multibitdepth off on aarch64-linux, so guard on the siblings existing rather
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
  # Merge in postInstall, NOT postBuild: the installPhase's `make install`
  # re-links libx265.a from the 8-bit objects only, overwriting anything a
  # postBuild step wrote. Operate on the INSTALLED archive using the still-
  # present build-dir siblings. CMake's own combine leaves `$out/lib/libx265.a`
  # with the 8-bit C API (`x265_api_get_*`) indexed but the 10/12-bit namespaced
  # entry points UNDEFINED — its llvm-ar combine dropped the same-basename
  # 10/12-bit `api.cpp.o`. Do NOT extract+rebuild the combined archive: it holds
  # DUPLICATE member basenames, and `ar x` overwrites collisions (losing the
  # 8-bit `api.cpp.o` that defines `x265_api_get_215`). Instead APPEND the
  # 10/12-bit members — each renamed with a unique prefix — onto the existing
  # archive with `ar rs`, which keeps every 8-bit member and rebuilds the full
  # symbol index. (Upstream's `postInstall = rm -f $out/lib/*.a`, fatal for
  # static, is discarded by not chaining `oa.postInstall`.)
  #
  # Object SUFFIX is target-dependent: CMake emits `.obj` for a Windows target
  # and `.o` everywhere else, so every glob here must cover both. A `*.o`-only
  # glob matched nothing on mingw, appended nothing, and did NOT fail — leaving
  # `x265_10bit::x265_api_get_*` undefined in a perfectly well-formed archive.
  # ffmpeg then reports that three packages downstream as "x265 not found using
  # pkg-config", because configure's pkg-config probe ends in a link test. Hence
  # the closing ARMAP assertion: a merge that appends nothing must fail HERE,
  # loudly, not surface as a misleading error in a consumer.
  postInstall = ''
    if [ -e libx265-10.a ] && [ -e libx265-12.a ]; then
      echo "appending libx265-10.a + libx265-12.a (renamed) → $out/lib/libx265.a"
      rm -rf x265-merge && mkdir -p x265-merge/m10 x265-merge/m12
      ( cd x265-merge/m10 && $AR x ../../libx265-10.a
        for f in *.o *.obj; do [ -e "$f" ] || continue; mv "$f" "b10_$f"; done )
      ( cd x265-merge/m12 && $AR x ../../libx265-12.a
        for f in *.o *.obj; do [ -e "$f" ] || continue; mv "$f" "b12_$f"; done )
      $AR rs "$out/lib/libx265.a" x265-merge/m10/b10_* x265-merge/m12/b12_*
      # Materialise the ARMAP before grepping it. `nm … | grep -q` is a trap
      # here: grep -q exits at the first match, nm (~100k lines) takes SIGPIPE,
      # and under the stdenv's `set -o pipefail` the pipeline reports THAT
      # failure — so the check fails precisely when the symbol IS present.
      "''${NM:-nm}" --print-armap "$out/lib/libx265.a" > x265-armap.txt
      if ! grep -q 'x265_10bit.*x265_api_get' x265-armap.txt; then
        echo "x265: merge appended no 10-bit entry points; aborting"
        echo "  AR=$AR  NM=''${NM:-nm}"
        echo "  extracted: m10=$(ls x265-merge/m10 | wc -l) m12=$(ls x265-merge/m12 | wc -l)"
        echo "  armap: $(wc -l < x265-armap.txt) lines, $(grep -c 'b10_' x265-armap.txt) b10_ members"
        exit 1
      fi
      rm -rf x265-merge x265-armap.txt
    else
      echo "multibitdepth siblings absent (aarch64-linux); skipping merge"
    fi
  '';
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
