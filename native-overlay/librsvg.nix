# pkgsStatic.librsvg, three cross-platform fixes:
#
# 1. `+ libunwind` (non-mingw). librsvg's meson runs
#    `rustc --print=native-static-libs` which emits `-lunwind` for
#    musl targets, then calls `cc.find_library('unwind', static: true)`.
#    Dynamic builds resolve `_Unwind_*` via libgcc_s at runtime —
#    pkgsStatic forces the static probe. GCC libunwind 1.8.x suffices.
#    On mingw, Rust uses SEH and libunwind doesn't build (POSIX
#    ucontext.h); the mingw-overlay handles that path separately.
#
# 2. Propagate pango. librsvg-2.0.pc declares
#    `Requires.private: pangocairo`; consumers using
#    `pkg-config --static librsvg-2.0` (ffmpeg) abort with
#    "Package 'pangocairo' not found" without it. See
#    [[requires-private-static-cross]].
#
# 3. `__clear_cache` (non-x86 Linux). rustc links the `rsvg-convert` bin
#    with `-nodefaultlibs`, pulling only `compiler_builtins` — which has no
#    `__clear_cache` on the non-x86 ISAs. libffi's executable closures
#    (`ffi_prep_closure_loc`) and pcre2's JIT (`sljit`), both C objects
#    dragged in via glib, reference it, so the link fails. Append `-lgcc`
#    to the cargo target rustflags; it lands after the rlib group, so the
#    archive resolves the pending refs. x86 never trips this
#    (`__clear_cache` is a no-op there).
#
# 4. doCheck restricted to x86_64-linux. nixpkgs gates librsvg's test suite
#    on `!isDarwin && !isi686`, so it still runs on aarch64/riscv64/armv7l.
#    There the doctest link hits the same `__clear_cache` gap (rustdoc reads
#    RUSTDOCFLAGS, which the fix #3 rustflags sed doesn't reach) and the
#    suite wants a fontconfig runtime the sandbox lacks. The tests exercise
#    upstream librsvg, not our static repackage, so keep them only on the
#    one arch where they pass clean.
#
# 5. `gcc_s` static shim (riscv64). Unlike other musl targets (which report
#    `unwind`, satisfied by fix #1), rustc's `--print=native-static-libs`
#    reports `gcc_s` on riscv64-musl, and meson.build:374 probes
#    `cc.find_library('gcc_s', static)`. Static musl ships no `libgcc_s.a`
#    (that's the shared unwinder); the static `_Unwind_*` live in
#    `libgcc_eh.a`. Symlink `libgcc_s.a -> libgcc_eh.a` onto the link path so
#    both the meson probe and the final rustc link resolve.
#
# 6. Strip the over-reported unwinder lib from librsvg-2.0.pc Libs.private
#    (ppc64le + riscv64). rustc's `--print=native-static-libs` appends an
#    unwinder that a static-musl `--static` consumer (ffmpeg) can't satisfy:
#      - ppc64le: `-lunwind`. Linking libunwind.a pulls its ppc64 unwinder
#        (`_Unwind_Backtrace`/`Resume`/`RaiseException`), which calls
#        `getcontext`/`setcontext` — musl never implemented ucontext for
#        powerpc64, so the link dies on undefined `getcontext`. (With
#        `-Wl,--export-dynamic`, DCE can't drop those objects.)
#      - riscv64: `-lgcc_s` (fix #5's territory). Static musl ships no
#        `libgcc_s.a` (it's the shared unwinder), so the consumer link
#        fails with `cannot find -lgcc_s`.
#    librsvg.a itself only needs `_Unwind_Resume`, a standard symbol
#    libgcc_eh provides (pulled implicitly by the cc static link), so
#    dropping either token is safe — consumers still resolve the unwind
#    refs. x86 musl ships ucontext and isn't affected; gate to the two
#    arches that over-report. Each sed is a no-op when its token is absent.
{ lib }:
pkgs:
let
  host = pkgs.stdenv.hostPlatform;
  isMinGW = host.isMinGW or false;
  needsClearCache = host.isLinux && !isMinGW && !host.isx86;
  isRiscV = host.isRiscV or false;
  isPower64 = host.isPower64 or false;
in
pkgs.librsvg.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ])
    ++ lib.optionals (!isMinGW) [ pkgs.libunwind ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ pkgs.pango ];

  # See fix #3 above.
  preBuild = (oa.preBuild or "") + lib.optionalString needsClearCache ''
    cfg=$(grep -rl --include=config.toml '"rustflags"' "$NIX_BUILD_TOP" | head -1)
    sed -i 's|"rustflags" = \[|"rustflags" = [ "-Clink-arg=-lgcc",|g' "$cfg"
  '';

  # See fix #5 above. Must be preConfigure: meson's find_library('gcc_s')
  # probe runs during the configure phase, before preBuild.
  preConfigure = (oa.preConfigure or "") + lib.optionalString isRiscV ''
    mkdir -p "$TMPDIR/gcc_s-shim"
    eh=$($CC -print-file-name=libgcc_eh.a)
    [ -f "$eh" ] || eh=$($CC -print-file-name=libgcc.a)
    ln -sf "$eh" "$TMPDIR/gcc_s-shim/libgcc_s.a"
    export NIX_LDFLAGS="''${NIX_LDFLAGS:-} -L$TMPDIR/gcc_s-shim"
  '';

  # See fix #4 above.
  doCheck = host.isx86_64 && host.isLinux;
}
# See fix #6 above. Gated via optionalAttrs so no other arch's librsvg
# derivation hash changes (postFixup stays absent off ppc64le/riscv64).
// lib.optionalAttrs (isPower64 || isRiscV) {
  postFixup = (oa.postFixup or "") + ''
    for pc in "''${dev:-$out}/lib/pkgconfig/librsvg-2.0.pc" "$out/lib/pkgconfig/librsvg-2.0.pc"; do
      [ -f "$pc" ] && sed -i -E 's/ -l(unwind|gcc_s)//g' "$pc" || true
    done
  '';
})
