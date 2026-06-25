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
# overlay isn't applied — see nixpkgsFor in flake.nix). The scope is marked
# `__unpinsGC = true` so `lib.gcSectionsFlag` can decide whether a downstream
# final link (e.g. a multicall.nix post-link, outside pkgName's own build)
# should add `--gc-sections`. Hash-neutral when off: no marker → empty flag →
# byte-identical link commands.
#
# Overlay (mirror of lto.nix), not a blanket stdenv tweak: a `withCFlags` on
# stdenv re-runs the bootstrap fixed-point and blows up in
# bootstrap-stage2-gcc-wrapper.

{ nixpkgs, appendCFlags, appendLinkFlags, lldRSafe }:

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
    then { __unpinsGC = true; }
    else {
      __unpinsGC = true;
      # Two final-link channels, both safe (neither reaches a direct `ld -r`):
      #   * makeFlagsArray LDFLAGS — reaches autotools/make final links, but
      #     CMake/meson IGNORE `make LDFLAGS=` (baked at configure).
      #   * NIX_CFLAGS_LINK (appendLinkFlags, env-aware) — honored by EVERY
      #     $CC-driven link, so CMake/meson single-binaries also get lld + gc.
      # make/autotools get both (doubled flags are idempotent). --icf=safe is a
      # no-op for uniformity; the size win is --gc-sections on the chain-wide
      # function-sections. `-B<lld>/bin` makes ld.lld findable on the
      # NIX_CFLAGS_LINK path (belt-and-suspenders with PATH).
      ${pkgName} = appendLinkFlags
        ((withGC super.${pkgName}).overrideAttrs (old: {
          buildInputs = map withGC (old.buildInputs or [ ]);
          propagatedBuildInputs = map withGC (old.propagatedBuildInputs or [ ]);
          # lldRSafe strips --icf on `$CC -r` partial-links (busybox kbuild
          # built-in.o), which both channels' --icf=safe would otherwise abort.
          nativeBuildInputs = (old.nativeBuildInputs or [ ])
            ++ [ (lldRSafe super.buildPackages) ];
          preBuild = (old.preBuild or "") + ''
            makeFlagsArray+=("LDFLAGS=$LDFLAGS -fuse-ld=lld -Wl,--gc-sections -Wl,--icf=safe")
          '';
        }))
        "-B${lldRSafe super.buildPackages}/bin -fuse-ld=lld -Wl,--gc-sections -Wl,--icf=safe";
    };
in
# Full pkgs scope (not the raw extended pkgsStatic) so `pkgs.pkgsStatic.<name>`
# reaches the overlay: pkgsStatic.pkgsStatic re-evaluates the fixed-point
# without it.
basePkgs // { pkgsStatic = basePkgs.pkgsStatic.extend gcOverlay; }
