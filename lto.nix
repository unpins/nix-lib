# Chain-wide LTO for unpins packages. Produces a pkgsStatic set where the
# target package and its (curated) LTO dependencies are rebuilt with
# `-flto -ffat-lto-objects`, `gcc-ar` for bitcode-aware archive indexing,
# `--gc-sections`, and `-Wl,-u,__stack_chk_fail` so stack protector keeps
# working after ltrans recompiles musl's printf chain.
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
#
# muslLTO is shared by all packages: musl's asm `_dlstart` -> C `_dlstart_c`
# external linkage breaks libc.so under LTO, so we disable shared.

{ nixpkgs, appendCFlags }:

{ system ? "x86_64-linux"
, opt ? "-O2"
, ssp ? true
, pkgName  # which target pkg in pkgsStatic we're building
}:

let
  basePkgs = import nixpkgs { inherit system; };
  triple = basePkgs.pkgsStatic.stdenv.hostPlatform.config;

  ltoCFlags = "${opt} -flto -ffat-lto-objects -ffunction-sections -fdata-sections"
            + (if ssp then "" else " -fno-stack-protector");

  # NIX_LDFLAGS is consumed by bintools-wrapper and passed straight to ld
  # (no gcc translation), so flags use ld syntax — not the `-Wl,...` form.
  #
  # `-u __stack_chk_fail/__stack_chk_guard` forces the LTO plugin to
  # retain SSP symbols whose only callers are assembly: ltrans recompiles
  # musl's printf chain and injects SSP refs with no LTO-visible caller,
  # so the def gets internalized away without these.
  ltoLDFlags = "--gc-sections"
             + (if ssp then " -u __stack_chk_fail -u __stack_chk_guard" else "");

  # AR/RANLIB/NM are PATH-resolved (cc-wrapper places the prefixed gcc
  # dir on PATH ahead of binutils), so plain `${triple}-gcc-ar` finds
  # the plugin-aware variant. NIX_CFLAGS_COMPILE goes via appendCFlags
  # (handles both top-level and legacy env.* sources).
  withLTO = drv: (appendCFlags drv ltoCFlags).overrideAttrs (old: {
    hardeningDisable = (old.hardeningDisable or [ ])
      ++ (if ssp then [ ] else [ "stackprotector" ]);
    NIX_LDFLAGS = (old.NIX_LDFLAGS or "")
      + " ${ltoLDFlags}";
    AR = "${triple}-gcc-ar";
    RANLIB = "${triple}-gcc-ranlib";
    NM = "${triple}-gcc-nm";
  });

  # Standalone muslLTO derivation — built once, NOT substituted into the
  # overlay. We can't substitute musl in scope because it forces a cross-
  # gcc-musl rebuild that fails (LTO breaks musl's libc.so link). Instead,
  # the target binary links against muslLTO's libc.a directly via
  # NIX_LDFLAGS (--whole-archive). Stock musl stays the toolchain libc;
  # only the final binary picks up the LTO libc bytes.
  #
  # Upstream outputs preserved (don't collapse) — keeping consumers that
  # reference musl.dev / musl.bin happy even though we only use $out/lib.
  muslLTO = basePkgs.pkgsStatic.musl.overrideAttrs (old: {
    pname = old.pname + "-lto";
    CFLAGS = (if ssp
              then (old.CFLAGS or [ ])
              else nixpkgs.lib.remove "-fstack-protector-strong" (old.CFLAGS or [ ]))
      ++ [ opt ]
      ++ (if ssp then [ ] else [ "-fno-stack-protector" ])
      ++ [ "-flto" "-ffat-lto-objects" ];
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
    # Linux kernel headers normally live under musl.dev; with a single
    # output, symlink them into $out/include so consumers via -isystem
    # work the same.
    postInstall = ''
      ln -sf ${basePkgs.pkgsStatic.musl.passthru.linuxHeaders}/include/* $out/include/ 2>/dev/null || true
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
  # musl in scope forces a cross-gcc-musl rebuild that fails because LTO
  # breaks musl's libc.so link inside that rebuild. Instead, we build a
  # separate muslLTO drv (above) and force-link its libc.a only into the
  # final target binary via withLTOTarget.
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
        # Force-link muslLTO/libc.a via --whole-archive on the FINAL
        # link only (via makeFlagsArray, NOT NIX_LDFLAGS, so autoconf
        # conftests don't trigger LTO between conftest + ncurses-LTO +
        # muslLTO bitcode — we saw that fail with ltrans dropping
        # `fwrite` from musl).
        #
        # Why not cc.libc = muslLTO (which would also LTO the crt
        # files)? Tried — the cc-wrapper assertion + bintools mirror
        # work, but applying it via wrapper means every conftest link
        # uses muslLTO + LTO-ed ncurses → ltrans DCE → broken probes.
        # cc.libc stays stock; crt files lose LTO (~1KB miss); the
        # target binary still picks up muslLTO via the manual link.
        preBuild = (old.preBuild or "") + ''
          makeFlagsArray+=("LDFLAGS=$LDFLAGS -Wl,--whole-archive ${muslLTO}/lib/libc.a -Wl,--no-whole-archive")
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
