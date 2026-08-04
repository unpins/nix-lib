# Chain-wide dead-code stripping: a pkgsStatic set where the target pkg + every
# direct (level-1) dep are rebuilt with `-ffunction-sections -fdata-sections`,
# so the final link can `--gc-sections` away unreachable sections.
#
# Cheap cousin of lto.nix: same section DCE but no bitcode/muslLTO/keep-syms/AR
# swap. function-sections is a benign, widely-deployed knob, so unlike the LTO
# chain it causes no systemic build failures — the only cost is lost
# cache.nixos.org hits for rebuilt deps. Measured: aom multicall 10.96 → 9.44 MB
# (−13.8%); the win scales with how much of the binary is our code vs C runtime.
#
# Linux-native only (musl); darwin/mingw/cosmo fall through to stock pkgs (the
# overlay isn't applied — see nixpkgsFor in flake.nix). A downstream final link
# outside pkgName's own build (a multicall post-link) decides on its own via
# `lib.gcSectionsFlag`, which reads the target platform — it does not consult
# this overlay, so the two are independent.
#
# Overlay (mirror of lto.nix), not a blanket stdenv tweak: a `withCFlags` on
# stdenv re-runs the bootstrap fixed-point and blows up in
# bootstrap-stage2-gcc-wrapper.

{ nixpkgs, appendCFlags, appendLinkFlags, lldRSafe, lldStdOpts, gcSectionsFlag }:

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

  # Bail out on buildInputs lacking `.overrideAttrs` (setup hooks, raw paths):
  # the only loss is section-DCE on a helper that never reaches the binary.
  withGC = drv:
    if !(builtins.isAttrs drv) || !(drv ? overrideAttrs) then drv
    else (appendCFlags drv gcCFlags).overrideAttrs (old: {
      hardeningDisable = (old.hardeningDisable or [ ])
        ++ (if ssp then [ ] else [ "stackprotector" ]);
    });

  # Level-1 cover like lto.nix (transitives barely show in the final binary).
  # --gc-sections goes via makeFlagsArray, not NIX_LDFLAGS, which would reach
  # `ld -r` partial-links where it errors "requires a defined symbol root".
  gcOverlay = self: super:
    let
      isStatic = super.stdenv.hostPlatform.isStatic or false;
    in
    if !isStatic || !(super ? ${pkgName})
    then { }
    else {
      # Two final-link channels, both safe (neither reaches a direct `ld -r`):
      #   * makeFlagsArray LDFLAGS — reaches autotools/make final links, but
      #     CMake/meson IGNORE `make LDFLAGS=` (baked at configure).
      #   * NIX_CFLAGS_LINK (appendLinkFlags, env-aware) — honored by EVERY
      #     $CC-driven link, so CMake/meson single-binaries also get lld + gc.
      # make/autotools get both (doubled flags are idempotent). Both channels
      # take the options from `lldStdOpts` rather than spelling them out, which
      # is how this file would keep a stale `--icf=safe` after the canonical set
      # changed. --icf=safe is a no-op for uniformity; the size win is
      # --gc-sections on the chain-wide function-sections.
      ${pkgName} = appendLinkFlags
        ((withGC super.${pkgName}).overrideAttrs (old: {
          buildInputs = map withGC (old.buildInputs or [ ]);
          propagatedBuildInputs = map withGC (old.propagatedBuildInputs or [ ]);
          # lldRSafe strips --icf on `$CC -r` partial-links (busybox kbuild
          # built-in.o), which both channels' --icf=safe would otherwise abort.
          nativeBuildInputs = (old.nativeBuildInputs or [ ])
            ++ [ (lldRSafe super.buildPackages) ];
          preBuild = (old.preBuild or "") + ''
            makeFlagsArray+=("LDFLAGS=$LDFLAGS ${lldStdOpts}")
          '';
        }))
        # Same `-B<lld>/bin ${lldStdOpts}` a multicall post-link gets, so the
        # in-build and post-link channels cannot drift apart.
        (gcSectionsFlag super);
    };
in
# Full pkgs scope (not the raw extended pkgsStatic) so `pkgs.pkgsStatic.<name>`
# reaches the overlay: pkgsStatic.pkgsStatic re-evaluates the fixed-point
# without it.
basePkgs // { pkgsStatic = basePkgs.pkgsStatic.extend gcOverlay; }
