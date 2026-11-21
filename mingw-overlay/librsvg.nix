# librsvg cross-mingw, three fixes:
#
# 1. `+ windows.pthreads + windows.mcfgthreads` — Rust mingw target
#    hardcodes `-l:libpthread.a`, and libgcc_eh/libstdc++ ref `_MCF_*`
#    (nixpkgs mingw gcc is `--enable-threads=mcf`). mcfgthread is the gcc
#    runtime's: the engine set (rust target `-gnullvm`, libc++/libunwind)
#    links neither libgcc_eh nor libstdc++, so it gets no mcfgthread, which
#    is otherwise the one thing there the mingw gcc builds.
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
#
# 4. In the engine set (`unpinRustBin`, see flake.nix), rust-overlay's prebuilt
#    rustc/cargo instead of nixpkgs' cross rustc, whose build drags in the
#    gcc-built mingw-w64 CRT.
{ lib }:
self: super:
let
  gnuRuntime = self.stdenv.hostPlatform.rust.rustcTarget == "x86_64-pc-windows-gnu";
in
(if self ? unpinRustBin
 then super.librsvg.override {
   rustc = self.unpinRustBin;
   rustPlatform = self.buildPackages.makeRustPlatform { rustc = self.unpinRustBin; cargo = self.unpinRustBin; };
   cargo-auditable-cargo-wrapper =
     self.buildPackages.cargo-auditable-cargo-wrapper.override { cargo = self.unpinRustBin; };
 }
 else super.librsvg).overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ]) ++ [ self.windows.pthreads ]
    ++ lib.optional gnuRuntime self.windows.mcfgthreads;
  # The build scripts (linux-gnu) link with the build cc, which reads the same
  # unsalted NIX_LDFLAGS/NIX_CFLAGS_* the engine cc does, so it is handed the
  # mingw libs (bfd: "file format not recognized"); link them with those unset.
  preBuild = (oa.preBuild or "") + lib.optionalString (self ? unpinRustBin) (
    let
      bcc = self.buildPackages.stdenv.cc;
      t = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] self.stdenv.buildPlatform.rust.rustcTarget);
    in ''
      printf '%s\n' '#!${self.buildPackages.runtimeShell}' \
        'unset NIX_LDFLAGS NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK' \
        'exec ${bcc}/bin/${bcc.targetPrefix}cc "$@"' > "$TMPDIR/build-cc"
      chmod +x "$TMPDIR/build-cc"
      export CARGO_TARGET_${t}_LINKER="$TMPDIR/build-cc"
    '') + ''
    export NIX_LDFLAGS_AFTER_x86_64_w64_mingw32="''${NIX_LDFLAGS_AFTER_x86_64_w64_mingw32:-} -lmingwex -lmsvcrt -lkernel32 -ladvapi32${lib.optionalString gnuRuntime " -lmcfgthread"}"
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
