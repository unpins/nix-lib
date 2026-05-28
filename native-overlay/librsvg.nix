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
# 3. aarch64-musl `__clear_cache` (aarch64-linux only). rustc links
#    the `rsvg-convert` bin with `-nodefaultlibs`, pulling only
#    `compiler_builtins` — which has no `__clear_cache` on aarch64.
#    libffi's executable closures (`ffi_prep_closure_loc`) and pcre2's
#    JIT (`sljit`), both C objects dragged in via glib, reference it,
#    so the link fails. Append `-lgcc` to the cargo target rustflags;
#    it lands after the rlib group, so the archive resolves the pending
#    refs. x86_64 never trips this (`__clear_cache` is a no-op there).
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  isAarch64Linux = pkgs.stdenv.hostPlatform.isAarch64
    && pkgs.stdenv.hostPlatform.isLinux;
in
pkgs.librsvg.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ])
    ++ lib.optionals (!isMinGW) [ pkgs.libunwind ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ pkgs.pango ];

  # See fix #3 above.
  preBuild = (oa.preBuild or "") + lib.optionalString isAarch64Linux ''
    cfg=$(grep -rl --include=config.toml '"rustflags"' "$NIX_BUILD_TOP" | head -1)
    sed -i 's|"rustflags" = \[|"rustflags" = [ "-Clink-arg=-lgcc",|g' "$cfg"
  '';
})
