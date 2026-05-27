# nixpkgs `pkgsStatic.librsvg`: meson runs
# `rustc --target=...-musl --print=native-static-libs` which prints
# `-lunwind -lc`, then calls `cc.find_library('unwind', static: true)`
# for each (librsvg meson.build:375). nixpkgs doesn't ship libunwind
# in librsvg's buildInputs because the dynamic-lib build resolves
# `_Unwind_*` via `libgcc_s` at runtime. In pkgsStatic the probe is
# hard-required and aborts with `find_library('unwind') not found`.
# Alpine builds librsvg as `.so` only and doesn't pass
# `-Ddefault_library=static`, so the probe never fires — that's why
# their APKBUILD looks clean.
#
# Fix: feed the GCC libunwind (1.8.x, ~250 KB) as a buildInput.
# `llvmPackages.libunwind` also works but is 4× the size; both export
# the same `_Unwind_*` ABI so the static link succeeds either way.
#
# mingw: Rust on mingw uses SEH for unwinding and `--print=native-static-libs`
# doesn't emit `-lunwind`; libunwind itself doesn't build there (POSIX
# `ucontext.h`). Skip libunwind.
#
# However, rust's `x86_64-pc-windows-gnu` target hardcodes
# `-l:libpthread.a` into its link line (winpthreads dependency for
# `std::thread`). The mingw cross stdenv doesn't pull
# `windows.pthreads` for non-pthread-aware C builds, so without an
# explicit buildInput the `rsvg-convert.exe` final link fails
# with `cannot find -l:libpthread.a`. Add it for mingw.
#
# Second mingw blocker: `rsvg-convert.exe` link pulls
# `gettext.libintl.a` via `cargo:rustc-link-lib=intl` (emitted by
# `gdk-pixbuf-sys`'s build script, which reads gdk-pixbuf-2.0.pc's
# `Libs: ... -lintl`). libintl.a contains objects with auto-import
# refs (`__imp__wgetcwd`, `__imp__wcsdup`, `__imp_isalnum`,
# `__imp_CreateEventA`, `__mingw_snwprintf`) that need `libmsvcrt.a`
# + `libkernel32.a` + `libmingwex.a` from the mingw-w64 runtime.
# These libs ARE in rust's `late_link_args` for `windows-gnu`, but
# ld is single-pass: when ld processes `-lintl` (cargo-emitted, in
# the user-libs section), the symbol-set frozen at that point
# doesn't contain those undef refs (they're inside libintl's
# member objects that haven't been pulled in yet). By the time
# libintl's archive members get pulled, ld has already passed
# msvcrt/kernel32/mingwex.
#
# Fix: re-mention the mingw runtime libs at the very END of the
# rustc invocation via NIX_RUSTFLAGS — that puts them AFTER
# everything (including late_link_args), giving ld one more
# resolution chance.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.librsvg.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ])
    ++ lib.optionals (!isMinGW) [ pkgs.libunwind ]
    ++ lib.optionals isMinGW    [
      pkgs.windows.pthreads
      # nixpkgs' mingw GCC is built with `--enable-threads=mcf`, so
      # `libgcc_eh.a` and `libstdc++.a` reference `_MCF_*` symbols
      # (e.g. `_MCF_tls_key_new`, `__MCF_tls_table_get`). Rust links
      # `-lgcc_eh` for exception handling on
      # `x86_64-pc-windows-gnu`, pulling these undef refs. The
      # symbols live in `libmcfgthread.a`. Cross-mingw consumers
      # that don't link `libgcc_eh` (most C libs) never trip this.
      pkgs.windows.mcfgthreads
    ];

  # librsvg-2.0.pc declares `Requires.private: pangocairo …`.
  # nixpkgs' librsvg keeps `pango` in `buildInputs` only — it
  # never propagates it because the public C API doesn't expose
  # pango types. Static consumers calling
  # `pkg-config --static librsvg-2.0` (ffmpeg with
  # `--pkg-config-flags=--static`) need pangocairo.pc on
  # PKG_CONFIG_PATH; without it, the probe fails with
  # `Package 'pangocairo' not found, required by librsvg-2.0`.
  # Propagate pango so its `.dev` (containing pangocairo.pc) is
  # on the consumer's PKG_CONFIG_PATH.
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [
    pkgs.pango
  ];

  # rsvg-convert.exe link line ordering:
  #   1. rustc-emitted libs (rlibs, -lintl indirectly via build scripts)
  #   2. cc-wrapper's `NIX_LDFLAGS_x86_64_w64_mingw32`
  #      (auto-populated from buildInputs `-L<store>/lib -lintl ...`)
  #   3. cc-wrapper's `NIX_LDFLAGS_AFTER_x86_64_w64_mingw32`
  #
  # gettext (libintl.a) is pulled via gdk-pixbuf-sys's build script
  # (cargo:rustc-link-lib=intl from gdk-pixbuf-2.0.pc `Libs: -lintl`).
  # libintl.a depends on mingw runtime libs (msvcrt: `_wgetcwd`,
  # `_wcsdup`, `isalnum`, `putc`, `fputwc`; kernel32: `CreateEventA`,
  # `EnumSystemLocalesA`, `GetLocaleInfoA`, `EnumResourceLanguagesA`,
  # `RegOpenKeyExA`, `RegQueryValueExA`; advapi32; mingwex:
  # `__mingw_snwprintf`).
  #
  # Rust's `late_link_args` for `x86_64-pc-windows-gnu` adds
  # `-lmsvcrt -lkernel32 -lmingwex` BEFORE the cc-wrapper's
  # NIX_LDFLAGS (= before `-lintl`), so ld single-pass passes them
  # before seeing libintl's undef refs. We need to re-mention them
  # AFTER `-lintl` in the link line.
  #
  # Setting via `CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS`
  # places the libs between rustc-emitted args and the cc-wrapper's
  # NIX_LDFLAGS — STILL before `-lintl`. The only env that lands
  # after NIX_LDFLAGS is `NIX_LDFLAGS_AFTER_<triple>`.
  # Order matters: `-lmingwex` comes BEFORE `-lmsvcrt` so the
  # libmingwex objects that wrap MS CRT funcs (e.g.
  # `mingw_wpformat.o` referencing `__ms_fwprintf`) get pulled
  # before ld processes msvcrt — single-pass ld resolves them on
  # the msvcrt pass. `-lmcfgthread` is also re-emitted at the
  # very end so libgcc_eh's `_MCF_*` refs resolve.
  preBuild = (oa.preBuild or "") + lib.optionalString isMinGW ''
    export NIX_LDFLAGS_AFTER_x86_64_w64_mingw32="''${NIX_LDFLAGS_AFTER_x86_64_w64_mingw32:-} -lmingwex -lmsvcrt -lkernel32 -ladvapi32 -lmcfgthread"
  '';

  # The default postInstall runs `wine64 rsvg-convert.exe
  # --completion {bash,fish,zsh}` to generate shell completion
  # files. On the Linux builder, wine can't fully bootstrap (no
  # display, missing services), and even when the exe links cleanly
  # against the static crt, wine fails to load it (c0000135).
  # Completions aren't useful on Windows anyway — drop the step.
  # Touch empty files so `installShellCompletion` finds something
  # to install (zero-size triggers its sanity check, so write a
  # 1-byte stub comment).
  postInstall = lib.optionalString isMinGW ''
    mkdir -p $out/share/bash-completion/completions
    echo "# rsvg-convert bash completion (not generated on cross build)" \
      > $out/share/bash-completion/completions/rsvg-convert.bash
    mkdir -p $out/share/fish/vendor_completions.d
    echo "# rsvg-convert fish completion (not generated on cross build)" \
      > $out/share/fish/vendor_completions.d/rsvg-convert.fish
    mkdir -p $out/share/zsh/site-functions
    echo "# rsvg-convert zsh completion (not generated on cross build)" \
      > $out/share/zsh/site-functions/_rsvg-convert
  '';
})
