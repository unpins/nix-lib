# librsvg cross-mingw, three fixes:
#
# 1. `+ windows.pthreads + windows.mcfgthreads`. Rust mingw target
#    hardcodes `-l:libpthread.a` for `std::thread`; libgcc_eh and
#    libstdc++ reference `_MCF_*` symbols because nixpkgs' mingw gcc
#    is built with `--enable-threads=mcf`. Cross-mingw C consumers
#    that don't link libgcc_eh never trip the mcf path.
#
# 2. preBuild: re-emit mingw runtime libs at the very END of the
#    link via `NIX_LDFLAGS_AFTER_<triple>`. libintl.a (pulled by
#    gdk-pixbuf-sys's `cargo:rustc-link-lib=intl`) references
#    msvcrt/kernel32/mingwex symbols. Rust's `late_link_args` adds
#    those BEFORE cc-wrapper's NIX_LDFLAGS (= before `-lintl`), so
#    ld's single pass misses them. `NIX_LDFLAGS_AFTER_<triple>` is
#    the only env that lands after NIX_LDFLAGS — CARGO_*_RUSTFLAGS
#    doesn't (still ordered before). Order matters: mingwex before
#    msvcrt (mingwex's CRT-wrapper objects need to be pulled in
#    before ld processes msvcrt), mcfgthread last (libgcc_eh refs).
#
# 3. postInstall stub. Upstream runs
#    `wine64 rsvg-convert.exe --completion {bash,fish,zsh}` to
#    generate completions; wine doesn't bootstrap on the Linux
#    builder. Write 1-byte stubs (zero-size trips
#    installShellCompletion's sanity check).
{ lib }:
self: super:
super.librsvg.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ]) ++ [
    self.windows.pthreads
    self.windows.mcfgthreads
  ];
  preBuild = (oa.preBuild or "") + ''
    export NIX_LDFLAGS_AFTER_x86_64_w64_mingw32="''${NIX_LDFLAGS_AFTER_x86_64_w64_mingw32:-} -lmingwex -lmsvcrt -lkernel32 -ladvapi32 -lmcfgthread"
  '';
  postInstall = ''
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
