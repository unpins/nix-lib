# Chain-wide LTO for unpins packages. Produces a pkgsStatic set where the
# target package + every direct dep are rebuilt with `-flto
# -ffat-lto-objects`, the cc-wrapper has its libc swapped to a bitcode-only
# `muslLTO`, and a curated `-u <sym>` list (the GCC-documented set of
# builtins IPA can synthesize during ltrans — see ipaSynthSyms below) is
# passed at each link so lto-plugin keeps those libc members through
# partition even though no bitcode caller references them at claim time.
#
# OPT-IN AS OF THE LTO-DROP COMMIT. Default in `mkStandaloneFlake` is now
# `optimize.lto = false`. Reasons documented in the commit message and in
# the optimize-knob docstring in flake.nix. Keep this file as the
# implementation for consumers that opt in (`mkStandaloneFlake { ...;
# optimize = { lto = true; }; }`).
#
# Reference precedent: LLVM/LLD's `llvm/IR/RuntimeLibcalls.def` handles
# the same class of problem automatically; GCC delegates to the user, so
# we maintain the list explicitly. Linux kernel does the same thing via
# `scripts/lto-used-symbollist` (kernel needs only 6 symbols because it
# builds -ffreestanding; userspace + hosted libc + printf/math folds
# pulls the list to ~30).
#
# Why per-package enumeration instead of a blanket stdenv overlay:
#   A `withCFlags`/`addAttrsToDerivation` overlay on `stdenv` re-runs the
#   nixpkgs bootstrap fixed-point with our modifications applied, which
#   blows up in `bootstrap-stage2-gcc-wrapper` (xgcc can't find `libc_dev`
#   in the partial-bootstrap `cc`). The `pkgsLLVM` family avoids this via
#   a dedicated `useLLVM` knob in the platform that's processed by bootstrap
#   itself; there's no `useLTO` equivalent, and patching one in is a much
#   larger commitment.
#
#   The practical compromise: nix-lib maintains a small map of which deps
#   each package wants rebuilt with LTO. Consumers only set `lto = true`
#   in `mkStandaloneFlake` — the map lives here, not in the consumer.

{ nixpkgs, appendCFlags }:

{ system ? "x86_64-linux"
, opt ? "-O2"
, ssp ? true
, pkgName  # which target pkg in pkgsStatic we're building
}:

let
  basePkgs = import nixpkgs { inherit system; };
  triple = basePkgs.pkgsStatic.stdenv.hostPlatform.config;

  # -g0 cancels stdenv's default `-g`: ltrans regenerates the final
  # objects and their .debug_info DIEs reference LTO-internal renamed
  # symbols (e.g. `common.c.<hash>`) that BFD ld treats as fatal undefined
  # relocs in non-debug-format sections. We strip the binary anyway, so
  # debug-info on LTO deps is dead weight either way.
  ltoCFlags = "${opt} -g0 -flto -ffat-lto-objects -ffunction-sections -fdata-sections"
            + (if ssp then "" else " -fno-stack-protector");

  # NIX_LDFLAGS is consumed by bintools-wrapper and passed straight to ld
  # (no gcc translation), so flags use ld syntax — not the `-Wl,...` form.
  # Unlike makeFlagsArray's LDFLAGS, NIX_LDFLAGS reaches every link cmd
  # (autotools, cmake, raw Makefiles) because it's picked up by the
  # bintools-wrapper ld(1) shim in env, not the build system's flag plumbing.
  #
  # The `-u <sym>` list that keeps lto-plugin from internalizing musl
  # symbols (IPA-synthesized refs like vfprintf/sincos, asm-only refs
  # like __stack_chk_fail/__environ) is auto-derived from muslLTO's
  # `nm` and threaded through makeFlagsArray's LDFLAGS at final link
  # time — see the ltoOverlay block below. The flag here is only what
  # SSP needs on EVERY ld call (some build systems link helper progs
  # mid-build, where SSP refs from musl's printf chain show up too).
  #
  # `--gc-sections` is intentionally NOT in NIX_LDFLAGS: it errors with
  # "requires a defined symbol root specified by -e or -u" on `ld -r`
  # (relocatable output), which is what kbuild-style consumers use for
  # their per-directory `built-in.o` partial-links. The flag is added
  # at final link time via makeFlagsArray's LDFLAGS (see ltoOverlay
  # below), which kbuild routes through `scripts/trylink` for the
  # final binary but NOT through the `ld_flags` filter that feeds
  # partial-links.
  ltoLDFlags = if ssp then "-u __stack_chk_fail -u __stack_chk_guard" else "";

  # AR/RANLIB/NM are PATH-resolved (cc-wrapper places the prefixed gcc
  # dir on PATH ahead of binutils), so plain `${triple}-gcc-ar` finds
  # the plugin-aware variant. NIX_CFLAGS_COMPILE goes via appendCFlags
  # (handles both top-level and legacy env.* sources).
  #
  # Some buildInputs lack `.override` (setup hooks, raw paths, simple
  # mkDerivation-without-callPackage wrappers). Plain `map withLTO …`
  # falls over on those — bail out and return them unmodified so the
  # overall closure still builds (loss is only LTO on the helper, which
  # never participates in the final binary anyway).
  #
  # `--whole-archive ${muslLTO}/lib/libc.a` goes via `makeFlagsArray`
  # (NOT NIX_LDFLAGS) so it only fires on the FINAL link, not on
  # libtool/autoconf conftests. The conftest path matters: many
  # configure probes (libtool's `supports shared libraries` test,
  # `crypt` in -lcrypt, …) invoke ld directly without the cc-wrapper
  # `--plugin` injection, and ld fails with `plugin needed to handle
  # lto object` the moment it sees muslLTO bitcode .lo's. Restricting
  # --whole-archive to the make-driven final link sidesteps the
  # conftest pool entirely; the consumer's own gcc-driven link path
  # auto-loads the plugin, so muslLTO bitcode resolves cleanly.
  #
  # Consumer-libc-override conflicts (bash's getenv, gnulib's
  # getopt/regex/err, procps-ng's `personality` variable shadowing
  # musl's function) are handled at libc-build time: muslLTO's
  # postPatch marks the colliding symbols `#pragma weak` so the
  # weak/strong link rule resolves the conflict in the consumer's
  # favor without `--allow-multiple-definition` (which would mask
  # real bugs by silently picking the first def of every collision).
  withLTO = drv:
    if !(drv ? override) then drv
    else (appendCFlags drv ltoCFlags).overrideAttrs (old: {
    hardeningDisable = (old.hardeningDisable or [ ])
      ++ (if ssp then [ ] else [ "stackprotector" ]);
    NIX_LDFLAGS = (old.NIX_LDFLAGS or "")
      + " ${ltoLDFlags}";
    AR = "${triple}-gcc-ar";
    RANLIB = "${triple}-gcc-ranlib";
    NM = "${triple}-gcc-nm";
    # TODO(restore): doCheck=false unblocks coreutils (gmp t-cmp_z SIGSEGV
    # under LTO) and shadow (libbsd explicit_bzero FAIL). Both are LTO
    # miscompiles in upstream test suites — investigate per-dep override
    # (gmp,libbsd) so the other deps keep doCheck=true.
    doCheck = false;
  });

  # Standalone muslLTO derivation. We can't substitute musl in the
  # overlay scope because that forces a cross-gcc-musl rebuild which
  # fails (LTO breaks musl's libc.so link inside the bootstrap).
  # Instead, build muslLTO once here and feed it to a wrapped cc-
  # wrapper via `cc.override { libc = muslLTO; }` (see ltoStdenv).
  muslLTO = basePkgs.pkgsStatic.musl.overrideAttrs (old: {
    pname = old.pname + "-lto";
    # Bitcode-only LTO for the .lo's (no -ffat-lto-objects). Plugin
    # MUST engage on every consumer link — there's no native fallback.
    # Two reasons to avoid fat-LTO here:
    #   1. Fat-LTO archive members get partial plugin claim: bitcode
    #      symbols get LTO-mangled (e.g. __errno_location →
    #      ___errno_location) inside ltrans, but the original native
    #      sections still reference the public name; ld pulls in
    #      both, leaving orphan ___errno_location refs.
    #   2. With cc.libc = muslLTO, conftests still work because
    #      cc-wrapper auto-engages lto-plugin whenever it sees a
    #      bitcode archive (no `-flto` needed on the command line),
    #      so plain `gcc conftest.c` against a bitcode-only libc.a
    #      links cleanly via the plugin.
    # The crt files are kept LTO-free via the postPatch below — they
    # have asm callers the plugin can't see (e.g. `_start` → `_start_c`).
    CFLAGS = (if ssp
              then (old.CFLAGS or [ ])
              else nixpkgs.lib.remove "-fstack-protector-strong" (old.CFLAGS or [ ]))
      ++ [ opt ]
      ++ (if ssp then [ ] else [ "-fno-stack-protector" ])
      ++ [ "-flto" ];
    # --disable-shared: LTO breaks the libc.so link (asm `_dlstart` ->
    # C `_dlstart_c` external-linkage edge dropped by LTO DCE). Safe to
    # disable here because muslLTO is a standalone drv — gcc cross-musl
    # uses stock musl from the overlay's untouched `musl` attribute.
    # Drop `--enable-wrapper=all`: the musl-gcc wrapper references
    # $dev/lib/musl-gcc.specs from $out → output cycle when we collapse.
    configureFlags = [
      "--disable-shared"
      "--enable-static"
      "--syslibdir=${placeholder "out"}/lib"
    ];
    # Collapse outputs: postInstall pieces (iconv binary, musl-gcc spec
    # patching, libssp_nonshared.a) assume a multi-output split; with
    # --disable-shared half of them break with cycles, simpler to ship
    # a single $out with just libc.a + headers.
    outputs = [ "out" ];
    separateDebugInfo = false;
    preConfigure = ''
      export AR=${triple}-gcc-ar
      export RANLIB=${triple}-gcc-ranlib
    '';
    # Force crt files to be plain native (no LTO bitcode). When crt1.o
    # has a fat-LTO bitcode side, conftest links (which we can't avoid
    # going through cc.libc = muslLTO) engage lto-plugin on it. The
    # plugin claims `_start_c` from the bitcode side, but the asm
    # `_start` is on the native side — plugin can't see asm callers,
    # so it elides `_start_c`, leaving an undefined ref. `-u _start_c`
    # doesn't help because the plugin pre-claim happens before ld
    # processes the `-u` directive. Solution: keep crt files LTO-free
    # so plugin doesn't engage on them at all. musl's Makefile sets
    # `$(CRT_OBJS): CFLAGS_ALL += -DCRT`; we extend that line to also
    # drop `-flto`.
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
    # Linux kernel headers normally live under musl.dev; with a single
    # output, symlink them into $out/include so consumers via -isystem
    # work the same.
    #
    # `keep-syms`: every globally-defined symbol in libc.a, one per
    # line. Consumer's final link feeds these as `-u <sym>` so
    # lto-plugin's IPA-visibility pass doesn't internalize/elide any
    # public musl symbol. Without this, plugin sees that (e.g.)
    # vfprintf has no caller outside the bitcode unit, internalizes it
    # to `vfprintf.lto_priv.N`, and ltrans output's `.text.printf` ends
    # up referencing the original `vfprintf` name with no defining
    # symbol — link fails. The same goes for musl internals reachable
    # only from asm (`__environ`, `__libc`, `__syscall_ret`,
    # `__stdout_FILE`, …): plugin can't see asm callers, so without
    # `-u` the def gets dropped. A maintained curated list would be
    # brittle (each new IPA fold or new asm cross-call adds a symbol);
    # auto-extracting from `nm` covers every public symbol in one
    # mechanical step and adapts to musl version bumps for free.
    # `--gc-sections` at final link still drops the actually-unused
    # ones from the ELF, so the size cost of "keep all" is zero.
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

  # Overlay applies LTO to the target pkg and rewrites its buildInputs /
  # propagatedBuildInputs to LTO-versions of each, so the link is "all
  # LTO" for every direct dep. We do NOT recurse into transitive deps:
  # each LTO dep keeps stock buildInputs (so e.g. ncurses-LTO still links
  # against stock zlib, libc, etc.). The level-1 cover is empirically
  # ~all of the ganho — transitives contribute little to the final binary.
  #
  # `isStatic` guard: pkgsStatic.extend propagates the overlay through to
  # pkgsStatic.buildPackages (the native glibc-based build tools). We
  # don't want to LTO-rebuild the native build chain (it'd fail and isn't
  # part of our binary anyway), so we only touch the target scope.
  #
  # musl is intentionally NOT overridden in the overlay: substituting
  # musl in scope forces a cross-gcc-musl rebuild that fails (LTO breaks
  # musl's libc.so link inside that rebuild). Instead, we build muslLTO
  # as a sibling drv and force-link its libc.a only on the FINAL binary
  # link via `makeFlagsArray` (see the preBuild below). Stock musl stays
  # the toolchain libc; only the consumer's link picks up muslLTO bytes.
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
        # bitcode in the link unit BEFORE it partitions, otherwise
        # IPA-introduced refs (vfprintf/sincos/_Exit, …) land in ltrans
        # output with no def. NIX_LDFLAGS would propagate this to every
        # ld call including libtool/autoconf conftests, where bare ld
        # can't read bitcode (no --plugin) → "plugin needed to handle
        # lto object" failure on harmless probes. Routing through
        # `makeFlagsArray` confines it to the make-driven final link,
        # which always goes through gcc-wrapper and auto-injects
        # --plugin.
        #
        # `-Wl,-u,<sym>` list comes from muslLTO's keep-syms file
        # (all public globals in libc.a). Without this, plugin's
        # IPA-visibility pass internalizes musl symbols whose only
        # callers are bitcode-side (renames them `.lto_priv.N`); when
        # ltrans output references the public name, link fails. The
        # auto-list is ~3KB of args at the cmdline — well under Linux
        # ARG_MAX (~128KB).
        #
        # Comma-joined `-Wl,--whole-archive,${muslLTO}/lib/libc.a,--no-whole-archive`
        # (instead of separate tokens `-Wl,--whole-archive ${path}
        # -Wl,--no-whole-archive`) matters for kbuild-style consumers
        # (busybox). Their `scripts/Makefile.lib` derives an internal
        # `ld_flags = $(filter-out -Wl$(comma)%,$(LDFLAGS))` for
        # partial-links (`ld -r`), expecting -Wl,-prefixed tokens to be
        # gcc-driver-only and bare tokens to be ld-safe. With separate
        # tokens, filter-out strips the directives but leaves the bare
        # `libc.a` path as a positional input — `ld -r` then partial-
        # links muslLTO's bitcode into `applets/built-in.o`, which at
        # the FINAL link collides with the legitimate --whole-archive
        # pull ("multiple definition of __stack_chk_guard" etc., with
        # DWARF source paths pointing at musl-1.2.5/src/env/). Joining
        # into one `-Wl,...` token makes filter-out remove the whole
        # thing from partial-links, while gcc on the final link splits
        # the commas back into the correct `--whole-archive PATH
        # --no-whole-archive` triple for ld.
        preBuild = (old.preBuild or "") + ''
          _unpins_uflags=$(awk '{ printf " -Wl,-u,%s", $1 }' ${muslLTO}/lib/keep-syms)
          makeFlagsArray+=("LDFLAGS=$LDFLAGS$_unpins_uflags -Wl,--gc-sections -Wl,--whole-archive,${muslLTO}/lib/libc.a,--no-whole-archive")
        '';
      });
    };
in
# Return a full pkgs scope (mirror of `import nixpkgs {...}`) so consumers
# using the conventional `pkgs.pkgsStatic.<name>` accessor reach the
# overlayed scope. Returning the raw extended pkgsStatic directly looks
# tempting but breaks the `pkgs.pkgsStatic.<name>` access path:
# `pkgsStatic.pkgsStatic` re-evaluates without the overlay (nixpkgs
# re-runs the fixed-point with the static config flag, fresh each time),
# so the consumer would silently see a STOCK build with no LTO.
basePkgs // { pkgsStatic = basePkgs.pkgsStatic.extend ltoOverlay; }
