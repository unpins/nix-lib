# Chain-wide LTO for unpins packages: a pkgsStatic set where the target pkg +
# every direct dep are rebuilt with `-flto -ffat-lto-objects`, cc-wrapper's
# libc swapped to a bitcode-only `muslLTO`, and a `-u <sym>` list passed at
# each link so lto-plugin keeps libc members through partition even when no
# bitcode caller references them at claim time.
#
# OPT-IN: default in `mkStandaloneFlake` is `optimize.lto = false`.
#
# GCC delegates the keep-sym problem to the user (LLD's RuntimeLibcalls.def
# handles it automatically), so we maintain the list explicitly.
#
# Per-package enumeration, not a blanket stdenv overlay: a `withCFlags` overlay
# on stdenv re-runs the nixpkgs bootstrap fixed-point and blows up in
# bootstrap-stage2-gcc-wrapper (no `useLTO` platform knob exists like
# `useLLVM`). So nix-lib keeps the dep map here; consumers only set `lto =
# true`.

{ nixpkgs, appendCFlags }:

{ system ? "x86_64-linux"
, opt ? "-O2"
, ssp ? true
, pkgName  # which target pkg in pkgsStatic we're building
}:

let
  basePkgs = import nixpkgs { inherit system; };
  triple = basePkgs.pkgsStatic.stdenv.hostPlatform.config;

  # -g0 cancels stdenv's default `-g`: ltrans .debug_info DIEs reference
  # LTO-renamed symbols (e.g. `common.c.<hash>`) that BFD ld treats as fatal
  # undefined relocs. We strip anyway, so the debug info is dead weight.
  ltoCFlags = "${opt} -g0 -flto -ffat-lto-objects -ffunction-sections -fdata-sections"
            + (if ssp then "" else " -fno-stack-protector");

  # NIX_LDFLAGS reaches every link cmd (bintools-wrapper ld shim, ld syntax),
  # so it carries only the SSP keep-syms needed on EVERY ld call (build systems
  # link helper progs mid-build, pulling SSP refs from musl's printf chain).
  # The full `-u <sym>` list and `--gc-sections` go via makeFlagsArray at final
  # link instead (see ltoOverlay): NIX_LDFLAGS would also hit `ld -r`
  # relocatable partial-links (kbuild built-in.o), where --gc-sections errors
  # "requires a defined symbol root specified by -e or -u".
  ltoLDFlags = if ssp then "-u __stack_chk_fail -u __stack_chk_guard" else "";

  # `${triple}-gcc-ar` (plugin-aware) is PATH-resolved ahead of binutils.
  # Bail out on buildInputs lacking `.override` (setup hooks, raw paths):
  # the only loss is LTO on a helper that never reaches the final binary.
  withLTO = drv:
    if !(drv ? override) then drv
    else (appendCFlags drv ltoCFlags).overrideAttrs (old: {
    hardeningDisable = (old.hardeningDisable or [ ])
      ++ (if ssp then [ ] else [ "stackprotector" ]);
    # Hand-rolled rather than `appendLdFlags`, for the same reason
    # `withDarwinIconv` is: the helper writes a bare `-u …` where this writes
    # " -u …", so the link line is identical and the hash is not. Unifying is a
    # deliberate rebuild, and nothing would catch an accidental one — no
    # drv-diff target sets `optimize`.
    NIX_LDFLAGS = (old.NIX_LDFLAGS or "")
      + " ${ltoLDFlags}";
    AR = "${triple}-gcc-ar";
    RANLIB = "${triple}-gcc-ranlib";
    NM = "${triple}-gcc-nm";
    # TODO(restore): doCheck=false works around LTO miscompiles in upstream
    # test suites (coreutils gmp t-cmp_z SIGSEGV, shadow libbsd
    # explicit_bzero). Narrow to a per-dep (gmp,libbsd) override.
    doCheck = false;
  });

  # Standalone muslLTO drv: substituting musl in the overlay scope forces a
  # cross-gcc-musl rebuild that fails (LTO breaks musl's libc.so link).
  muslLTO = basePkgs.pkgsStatic.musl.overrideAttrs (old: {
    pname = old.pname + "-lto";
    # Bitcode-only (no -ffat-lto-objects). Fat-LTO would get partial plugin
    # claim: bitcode symbols LTO-mangled (__errno_location → ___errno_location)
    # while native sections still reference the public name → orphan refs.
    # Bitcode-only works for conftests because cc-wrapper auto-engages the
    # plugin on any bitcode archive (no `-flto` needed on the cmdline).
    CFLAGS = (if ssp
              then (old.CFLAGS or [ ])
              else nixpkgs.lib.remove "-fstack-protector-strong" (old.CFLAGS or [ ]))
      ++ [ opt ]
      ++ (if ssp then [ ] else [ "-fno-stack-protector" ])
      ++ [ "-flto" ];
    # --disable-shared: LTO breaks the libc.so link (asm `_dlstart` → C
    # `_dlstart_c` edge dropped by LTO DCE). Safe because muslLTO is standalone
    # — gcc cross-musl still uses the overlay's untouched `musl`. Dropping
    # --enable-wrapper=all avoids a $dev→$out cycle once outputs collapse.
    configureFlags = [
      "--disable-shared"
      "--enable-static"
      "--syslibdir=${placeholder "out"}/lib"
    ];
    # Single output: stock postInstall pieces assume a multi-output split and
    # break with cycles under --disable-shared. Ship just libc.a + headers.
    outputs = [ "out" ];
    separateDebugInfo = false;
    preConfigure = ''
      export AR=${triple}-gcc-ar
      export RANLIB=${triple}-gcc-ranlib
    '';
    # Keep crt files LTO-free: with bitcode crt1.o, conftest links engage the
    # plugin, which claims `_start_c` from bitcode but can't see its asm caller
    # `_start` and elides it → undefined ref. `-u _start_c` doesn't help (plugin
    # pre-claim happens before ld reads `-u`). musl sets `$(CRT_OBJS):
    # CFLAGS_ALL += -DCRT`; we extend that line to also drop `-flto`.
    postPatch = (old.postPatch or "") + ''
      sed -i 's|^$(CRT_OBJS): CFLAGS_ALL += -DCRT$|$(CRT_OBJS): CFLAGS_ALL += -DCRT -fno-lto|' Makefile
      grep -q -- '-fno-lto' Makefile || { echo "muslLTO: failed to patch CRT_OBJS CFLAGS"; exit 1; }

      # Mark a small set of libc symbols as weak so consumers that ship
      # their own replacement (bash's shell-builtin env getters, gnulib's
      # libc-replacement modules) can override at static-link time.
      # Without this, `--whole-archive muslLTO/libc.a` forces musl's
      # strong def in alongside the consumer's, producing "multiple
      # definition" at link. Weak/strong rule resolves cleanly: consumer
      # strong wins, libc weak fills in symbols the consumer didn't
      # provide. Only the symbols on the conflict list are weakened —
      # this is the conservative cut, not a blanket weakening. Add to
      # the list when a new collision surfaces.
      #
      # `#pragma weak <sym>` propagates to the next definition in TU
      # (GCC docs, Pragmas). We inject it via `-include` in CFLAGS_ALL
      # so every .c sees the pragmas before any function definition.
      cat > weak-overrides.h <<'EOF'
      /* bash: shell-builtin env semantics override these. */
      #pragma weak getenv
      #pragma weak putenv
      #pragma weak setenv
      #pragma weak unsetenv

      /* gnulib: getopt module ships a full replacement when AC_CHECK_FUNCS
       * disagrees with muslLTO's bitcode-only autoconf view. */
      #pragma weak getopt
      #pragma weak getopt_long
      #pragma weak getopt_long_only
      #pragma weak optarg
      #pragma weak optind
      #pragma weak optopt
      #pragma weak opterr

      /* gnulib: regex module always compiles its own (musl's regex is
       * BSD-derived, gnulib's is glibc-derived). */
      #pragma weak regcomp
      #pragma weak regexec
      #pragma weak regfree
      #pragma weak regerror

      /* gnulib: err.h functions, BSD-flavored, gnulib always provides. */
      #pragma weak err
      #pragma weak errx
      #pragma weak warn
      #pragma weak warnx

      /* procps-ng: `unsigned personality = 0xffffffff;` in src/ps/global.c
       * shadows musl's `int personality(unsigned long persona)` syscall
       * wrapper. With both in the LTO unit, lto1 errors with "variable
       * 'personality' redeclared as function". Weak musl so consumer's
       * variable wins; procps-ng never calls personality() so dropping
       * the syscall wrapper is harmless. */
      #pragma weak personality
      EOF
      # $(CURDIR) is GNU make's absolute cwd, which equals the musl build
      # root (where Makefile lives + where compiles are invoked from).
      # `-include weak-overrides.h` without path also works since gcc
      # resolves relative -include against the compiler's cwd, but the
      # absolute form is robust if upstream ever cd's into a subdir.
      sed -i 's|^CFLAGS_ALL = |CFLAGS_ALL = -include $(CURDIR)/weak-overrides.h |' Makefile
      grep -q 'weak-overrides.h' Makefile || { echo "muslLTO: failed to inject weak-overrides.h"; exit 1; }
    '';
    # Symlink kernel headers into $out/include (normally under musl.dev; we
    # collapsed to one output).
    #
    # `keep-syms`: every global symbol in libc.a, fed to the consumer's final
    # link as `-u <sym>` so lto-plugin's IPA pass doesn't internalize public
    # musl symbols whose only callers are bitcode-side or asm-side (it renames
    # them `.lto_priv.N`, then ltrans output references the original name →
    # undefined). Auto-extracting from `nm` beats a curated list (each IPA fold
    # or asm cross-call adds a symbol); `--gc-sections` drops the unused ones
    # anyway, so keep-all costs zero size.
    postInstall = ''
      ln -sf ${basePkgs.pkgsStatic.musl.passthru.linuxHeaders}/include/* $out/include/ 2>/dev/null || true
      # gcc-nm loads liblto_plugin.so via gcc-driver, so bitcode .lo
      # members in libc.a expose their public globals. Plain
      # `${triple}-nm` would only show the handful of asm/crt symbols
      # (44 vs ~2k) and the resulting -u list would miss everything
      # that needs retention.
      ${triple}-gcc-nm -g --defined-only $out/lib/libc.a \
        | awk '$2 ~ /^[TRDBGW]$/ && $3 != "" { print $3 }' \
        | sort -u > $out/lib/keep-syms
      # Sanity check: must be >500 syms or upstream changed something
      # fundamental about how bitcode exports.
      _count=$(wc -l < $out/lib/keep-syms)
      [ "$_count" -ge 500 ] || { echo "muslLTO: keep-syms has only $_count syms (expected >=500), gcc-nm not seeing bitcode?"; exit 1; }
    '';
  });

  # LTO the target pkg + rewrite its direct buildInputs to LTO-versions
  # (level-1 only: transitive deps contribute little to the final binary).
  # `isStatic` guard keeps the overlay off pkgsStatic.buildPackages (the native
  # build chain, which would fail to LTO-rebuild and isn't in our binary).
  # muslLTO is force-linked only on the FINAL link via makeFlagsArray (see
  # preBuild), not overridden in scope (that rebuild fails, as above).
  ltoOverlay = self: super:
    let
      isStatic = super.stdenv.hostPlatform.isStatic or false;
    in
    if !isStatic || !(super ? ${pkgName})
    then { }
    else {
      ${pkgName} = (withLTO super.${pkgName}).overrideAttrs (old: {
        buildInputs = map withLTO (old.buildInputs or [ ]);
        propagatedBuildInputs = map withLTO (old.propagatedBuildInputs or [ ]);
        # Final-link-only --whole-archive: lto-plugin needs all of musl's
        # bitcode in the link unit before it partitions, else IPA-introduced
        # refs (vfprintf/sincos/_Exit) land in ltrans output with no def. Via
        # makeFlagsArray, not NIX_LDFLAGS, which would hit libtool/autoconf
        # conftests where bare ld can't read bitcode ("plugin needed to handle
        # lto object").
        #
        # `-Wl,-u,<sym>` comes from keep-syms (see muslLTO postInstall).
        #
        # Comma-joined `-Wl,--whole-archive,PATH,--no-whole-archive` as one
        # token (not separate tokens) is required for kbuild consumers
        # (busybox): their `ld_flags = $(filter-out -Wl$(comma)%,$(LDFLAGS))`
        # for `ld -r` partial-links would, with separate tokens, strip the
        # directives but leave the bare `libc.a` path as a positional input,
        # partial-linking musl bitcode into built-in.o → "multiple definition"
        # at the final link. One token gets filtered out whole; gcc splits the
        # commas back for ld on the final link.
        preBuild = (old.preBuild or "") + ''
          _unpins_uflags=$(awk '{ printf " -Wl,-u,%s", $1 }' ${muslLTO}/lib/keep-syms)
          makeFlagsArray+=("LDFLAGS=$LDFLAGS$_unpins_uflags -Wl,--gc-sections -Wl,--whole-archive,${muslLTO}/lib/libc.a,--no-whole-archive")
        '';
      });
    };
in
# Full pkgs scope (not the raw extended pkgsStatic) so `pkgs.pkgsStatic.<name>`
# reaches the overlay: `pkgsStatic.pkgsStatic` re-evaluates the fixed-point
# without it, silently yielding a stock no-LTO build.
basePkgs // { pkgsStatic = basePkgs.pkgsStatic.extend ltoOverlay; }
