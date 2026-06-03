# Chain-wide dead-code stripping for unpins packages. Produces a pkgsStatic
# set where the target package + every direct (level-1) dep are rebuilt with
# `-ffunction-sections -fdata-sections`, so the final link can drop every
# function/data section no live symbol reaches (`--gc-sections`).
#
# This is the cheap cousin of lto.nix: same section-granularity DCE, but no
# bitcode, no muslLTO, no -u keep-syms, no AR/RANLIB swap. function-sections
# is a benign, widely-deployed codegen knob (distros enable it broadly), so
# unlike the LTO chain it has not produced systemic build failures — the only
# real cost is losing cache.nixos.org hits for the rebuilt deps.
#
# Measured: aom multicall 10.96 MB → 9.44 MB (−13.8%) on x86_64-linux-musl.
# The win scales with how much of the binary is *our* (rebuilt) code vs the
# C runtime; codec/tool CLIs where libaom-class deps dominate benefit most.
#
# Linux-native only (musl). Darwin uses `-dead_strip` and a different ld; the
# cross-darwin / mingw / cosmo paths fall through to stock pkgs for now (the
# overlay simply isn't applied — see nixpkgsFor in flake.nix). The scope is
# marked with `__unpinsGC = true` so `lib.gcSectionsFlag` can decide whether a
# downstream final link (e.g. a multicall.nix post-link, which happens OUTSIDE
# pkgName's own build) should add `--gc-sections`. Hash-neutral when off: a
# scope without the marker yields an empty flag, so non-gc packages' link
# commands are byte-identical.
#
# Why an overlay (mirror of lto.nix) and not a blanket stdenv tweak: a
# `withCFlags` on stdenv re-runs the nixpkgs bootstrap fixed-point and blows up
# in bootstrap-stage2-gcc-wrapper. The overlay touches only the target scope.

{ nixpkgs, appendCFlags, appendLinkFlags }:

{ system ? "x86_64-linux"
, ssp ? true
, opt ? null
, pkgName  # which target pkg in pkgsStatic we're rebuilding
}:

let
  basePkgs = import nixpkgs { inherit system; };

  gcCFlags = "-ffunction-sections -fdata-sections"
    + (if opt == null then "" else " ${opt}")
    + (if ssp then "" else " -fno-stack-protector");

  # Some buildInputs lack `.override`/`.overrideAttrs` (setup hooks, raw
  # paths). Bail out unmodified on those so the closure still builds — the
  # loss is only section-granularity on a helper that never reaches the binary.
  withGC = drv:
    if !(builtins.isAttrs drv) || !(drv ? overrideAttrs) then drv
    else (appendCFlags drv gcCFlags).overrideAttrs (old: {
      hardeningDisable = (old.hardeningDisable or [ ])
        ++ (if ssp then [ ] else [ "stackprotector" ]);
    });

  # Mirror lto.nix's level-1 cover: target pkg + its direct buildInputs /
  # propagatedBuildInputs. Transitive deps keep stock builds (empirically
  # ~all of the size win is in level-1; transitives barely show in the
  # final binary). `--gc-sections` on pkgName's OWN final link goes via
  # makeFlagsArray (NOT NIX_LDFLAGS), exactly like lto.nix: NIX_LDFLAGS would
  # reach `ld -r` relocatable partial-links, where --gc-sections errors with
  # "requires a defined symbol root specified by -e or -u".
  gcOverlay = self: super:
    let
      isStatic = super.stdenv.hostPlatform.isStatic or false;
    in
    if !isStatic || !(super ? ${pkgName})
    then { __unpinsGC = true; }
    else {
      __unpinsGC = true;
      # Two final-link channels, both safe (neither reaches a direct `ld -r`
      # partial-link, where --gc-sections/--icf would error):
      #   * makeFlagsArray LDFLAGS — make-time, reaches autotools/make final
      #     links ($CC). CMake/meson IGNORE `make LDFLAGS=` (they bake link
      #     flags at configure), so a CMake/meson single-binary would silently
      #     fall back to GNU ld with no --gc-sections.
      #   * NIX_CFLAGS_LINK (appendLinkFlags, env-aware) — the cc-wrapper
      #     link channel that EVERY $CC-driven link honors (make, CMake,
      #     meson), and which never touches a direct `ld -r`. This is what
      #     makes CMake/meson single-binary targets actually use lld + gc.
      # make/autotools packages get both (idempotent: doubled -fuse-ld=lld /
      # --gc-sections / --icf=safe is harmless). lld is the unpins linker for
      # all non-darwin targets (this overlay is Linux-only → host is always
      # non-darwin); --icf=safe is a uniformity no-op, the size win comes from
      # --gc-sections biting the chain-wide function-sections. `-B<lld>/bin`
      # makes ld.lld findable for the NIX_CFLAGS_LINK path even though lld is
      # also on PATH via nativeBuildInputs (belt-and-suspenders).
      ${pkgName} = appendLinkFlags
        ((withGC super.${pkgName}).overrideAttrs (old: {
          buildInputs = map withGC (old.buildInputs or [ ]);
          propagatedBuildInputs = map withGC (old.propagatedBuildInputs or [ ]);
          nativeBuildInputs = (old.nativeBuildInputs or [ ])
            ++ [ super.buildPackages.lld ];
          preBuild = (old.preBuild or "") + ''
            makeFlagsArray+=("LDFLAGS=$LDFLAGS -fuse-ld=lld -Wl,--gc-sections -Wl,--icf=safe")
          '';
        }))
        "-B${super.buildPackages.lld}/bin -fuse-ld=lld -Wl,--gc-sections -Wl,--icf=safe";
    };
in
# Return a full pkgs scope (mirror of `import nixpkgs {...}`) so consumers
# using `pkgs.pkgsStatic.<name>` reach the overlayed scope. Returning the raw
# extended pkgsStatic directly breaks that access path (pkgsStatic.pkgsStatic
# re-evaluates the fixed-point without the overlay).
basePkgs // { pkgsStatic = basePkgs.pkgsStatic.extend gcOverlay; }
