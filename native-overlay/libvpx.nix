# pkgsStatic.libvpx — darwin + engine fixes (mingw via mingw-overlay/libvpx.nix).
#
# Darwin (two stacked issues):
# 1. package.nix reads `osxMinVersion`, renamed to `darwinMinVersion` upstream
#    but not updated here → eval crashes `attribute 'osxMinVersion' missing`.
#    Inject a stand-in; real deployment target set via configureFlags below.
# 2. With the bridged value the target maps to `darwin14` (macOS 10.10) and
#    configure injects `-mmacosx-version-min=10.10`, which the 14.4 SDK rejects
#    on `CLOCK_MONOTONIC_RAW` (10.12+). Rewrite the target to `darwin23`.
#
# Engine (all OSes), two breakages in libvpx's custom Makefile:
# 1. Per-object `.d` depfiles (`-MMD`) record the compiler's system headers as
#    make prerequisites. The engine clang serves libc from a VIRTUAL VFS root
#    (`/__unpin_ziglib__/…`, see toolchain/unpin_clang_vfs.cpp) with no on-disk
#    existence, so make sees `/__unpin_ziglib__/…/string.h` as a prereq with no
#    rule and aborts (`No rule to make target …`). `--disable-dependency-
#    tracking` turns off the `.d` emission (incremental rebuild is meaningless
#    in a one-shot nix build anyway).
# 2. libvpx probes `$(STRIP) -V | grep GNU` and, believing it has GNU strip,
#    post-processes each `lib%.a` via `$(STRIP) --strip-debug -o %.a %_g.a`. The
#    engine compiles `-flto`, so the archive members are LLVM BITCODE, which
#    llvm-strip rejects (`not recognized as a valid object file`). Force
#    `HAVE_GNU_STRIP=no` (make-var override) → libvpx's own `cp %_g.a %.a`
#    fallback; nix's fixupPhase does the real strip later.
# 3. armv7l only: the 32-bit NEON kernels ship as RVCT assembly, converted by
#    `ads2gas.pl` and assembled with `$(AS)` — which `setup_gnu_toolchain`
#    defaults to a BARE `as` (`AS=${AS:-${CROSS}as}`, and `--as=yasm` is read
#    only by the x86 branch). The engine has no standalone assembler at all:
#    clang assembles internally, so its bintools wrapper ships ar/ld/nm/strip
#    but no `as`. Drive it through the compiler, exactly as libvpx itself does
#    for arm/win32 (`AS="$CC -c"`). Other arches never reach this: x86 picks
#    yasm, and on aarch64/ppc64le/riscv64 the SIMD is C intrinsics.
# Gated on the engine cc so a non-engine build is byte-identical.
{ lib }:
let
  engineFix = pkgs: drv:
    if lib.isUnpinEngine pkgs
    then
      drv.overrideAttrs
        (oa: {
          configureFlags = (oa.configureFlags or [ ]) ++ [ "--disable-dependency-tracking" ];
          makeFlags = (oa.makeFlags or [ ]) ++ [ "HAVE_GNU_STRIP=no" ];
          preConfigure = (oa.preConfigure or "")
            + lib.optionalString pkgs.stdenv.hostPlatform.isAarch32 ''
            export AS="$CC -c"
          '';
        })
    else drv;
in
pkgs:
if pkgs.stdenv.hostPlatform.isDarwin
then
  engineFix pkgs
    ((pkgs.libvpx.override {
      stdenv = pkgs.stdenv // {
        hostPlatform = pkgs.stdenv.hostPlatform // {
          osxMinVersion = "10.10";
        };
      };
    }).overrideAttrs (oa: {
      configureFlags =
        (builtins.filter
          (f: !(lib.hasPrefix "--target=x86_64-darwin" f
          || lib.hasPrefix "--target=arm64-darwin" f
          || lib.hasPrefix "--target=aarch64-darwin" f))
          oa.configureFlags)
        ++ [
          "--target=${
          if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"
        }-darwin23-gcc"
        ];
    }))
else engineFix pkgs pkgs.libvpx
