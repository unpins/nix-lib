# librsvg cross-mingw, three fixes:
#
# 1. `+ windows.pthreads + windows.mcfgthreads` — Rust mingw target
#    hardcodes `-l:libpthread.a`, and libgcc_eh/libstdc++ ref `_MCF_*`
#    (nixpkgs mingw gcc is `--enable-threads=mcf`).
#
# 2. preBuild re-emits mingw runtime libs at the very END of the link via
#    `NIX_LDFLAGS_AFTER_<triple>` — libintl.a (from gdk-pixbuf-sys) refs
#    msvcrt/kernel32/mingwex, but Rust's `late_link_args` adds them before
#    NIX_LDFLAGS so ld's single pass misses them; this is the only env that
#    lands after NIX_LDFLAGS. Order: mingwex before msvcrt, mcfgthread last.
#
# 3. postInstall stubs the shell completions — upstream generates them via
#    `wine64 rsvg-convert.exe`, but wine doesn't bootstrap on the Linux
#    builder. 1-byte, not zero (installShellCompletion rejects empty).
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
