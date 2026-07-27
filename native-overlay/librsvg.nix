# pkgsStatic.librsvg, cross-platform fixes:
#
# 1. `+ libunwind` (non-mingw). librsvg's meson probes
#    `cc.find_library('unwind', static)` because rustc reports `-lunwind` for
#    musl; pkgsStatic forces the static probe (dynamic resolves via libgcc_s).
#    On mingw Rust uses SEH and libunwind doesn't build (POSIX ucontext.h);
#    the mingw-overlay handles that separately.
#
# 2. Propagate pango. librsvg-2.0.pc's `Requires.private: pangocairo` else
#    `pkg-config --static librsvg-2.0` (ffmpeg) aborts. See
#    [[requires-private-static-cross]].
#
# 3. `__clear_cache` (non-x86 Linux). rustc links rsvg-convert with
#    `-nodefaultlibs`, so only compiler_builtins — which lacks `__clear_cache`
#    on non-x86 ISAs — is available, but libffi closures and pcre2's JIT
#    (via glib) reference it. Append `-lgcc` to the cargo rustflags; it lands
#    after the rlib group and resolves the refs. No-op on x86.
#
# 3b. `-lshell32` (mingw). glib 2.88.1's win32 gio objects (archived into
#    librsvg's rlib) reference shell32 APIs (`SHFileOperationW`,
#    `CommandLineToArgvW`, …) that gio-2.0.pc's Libs.private never listed, so
#    the link dies on `__imp_SH*`. Same rustflags channel as #3. See
#    [[feedback_mingw_libs_private_winapis]].
#
# 4. doCheck restricted to x86_64-linux. nixpkgs runs the suite on
#    aarch64/riscv64/armv7l too, where the doctest link hits the same
#    `__clear_cache` gap (rustdoc reads RUSTDOCFLAGS, which #3's sed misses)
#    and wants a fontconfig runtime the sandbox lacks. The tests exercise
#    upstream librsvg, not our repackage.
#
# 5. `gcc_s` static shim (riscv64). rustc reports `gcc_s` (not `unwind`) on
#    riscv64-musl, so meson.build:374 probes `cc.find_library('gcc_s')`.
#    Static musl ships no libgcc_s.a (the static `_Unwind_*` live in
#    libgcc_eh.a), so symlink `libgcc_s.a -> libgcc_eh.a` onto the link path.
#
# 6. Strip the over-reported unwinder lib from librsvg-2.0.pc Libs.private
#    (ppc64le + riscv64 + i686). rustc appends an unwinder a static-musl
#    `--static` consumer (ffmpeg) can't satisfy:
#      - ppc64le: `-lunwind` pulls libunwind's ppc64 unwinder, which calls
#        `getcontext`/`setcontext` — musl has no ucontext for powerpc64.
#      - riscv64: `-lgcc_s`, which static musl doesn't ship (see #5).
#      - i686: `-lunwind` — libunwind's `_Unwind_Resume` object for 32-bit x86
#        (`x86/Gos-linux.c`) resumes via libc `setcontext`, which the musl i686
#        sysroot doesn't provide → undefined at the static link. (x86_64 is
#        unaffected: libunwind ships its own `x86_64/setcontext.S`, so its
#        `_Unwind_Resume` is self-contained.)
#    librsvg.a itself only needs `_Unwind_Resume` (the engine's LLVM libunwind
#    provides a clean one via `--extra-libs=-lunwind`; off-engine, libgcc_eh),
#    so dropping the token is safe. Each sed is a no-op when absent.
#
# 7. Propagate `darwin.libresolv` (darwin). librsvg is a Rust `staticlib`, so
#    librsvg-2.a BUNDLES the objects of every native library it linked —
#    including glib's `gthreadedresolver.c.o`, which calls `res_9_ninit`/
#    `res_9_nquery`/`res_9_dn_expand`. gio-2.0.pc lists `-lresolv` but a
#    consumer that reaches librsvg WITHOUT glib's own `.pc` (ffmpeg finds it via
#    librsvg-2.0.pc) gets the token with no `-L`: `ld64.lld: library not found
#    for -lresolv`, then those symbols undefined. native-overlay/glib.nix adds
#    libresolv for its HEADERS only — its note that "the res_* symbols are in
#    libSystem" does not hold for this link — so the search path has to travel
#    with the archive that carries the references.
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
  # See fix #7 below for libresolv.
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ pkgs.pango ]
    ++ lib.optional (host.isDarwin or false) pkgs.darwin.libresolv;

  # See fix #3 / #3b above.
  preBuild = (oa.preBuild or "")
    + lib.optionalString needsClearCache ''
      cfg=$(grep -rl --include=config.toml '"rustflags"' "$NIX_BUILD_TOP" | head -1)
      sed -i 's|"rustflags" = \[|"rustflags" = [ "-Clink-arg=-lgcc",|g' "$cfg"
    ''
    + lib.optionalString isMinGW ''
      cfg=$(grep -rl --include=config.toml '"rustflags"' "$NIX_BUILD_TOP" | head -1)
      sed -i 's|"rustflags" = \[|"rustflags" = [ "-Clink-arg=-lshell32",|g' "$cfg"
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
# derivation hash changes (postFixup stays absent off ppc64le/riscv64/i686).
// lib.optionalAttrs (isPower64 || isRiscV || host.isx86_32) {
  postFixup = (oa.postFixup or "") + ''
    for pc in "''${dev:-$out}/lib/pkgconfig/librsvg-2.0.pc" "$out/lib/pkgconfig/librsvg-2.0.pc"; do
      [ -f "$pc" ] && sed -i -E 's/ -l(unwind|gcc_s)//g' "$pc" || true
    done
  '';
})
