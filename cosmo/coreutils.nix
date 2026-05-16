# coreutils via mkPkgsCosmo for Windows-x86_64.
#
# Strategy: take nixpkgs's coreutils derivation but pin the source to the
# upstream 9.4 tarball that `ahgamut/superconfigure` validated against cosmo.
# nixpkgs ships 9.8, whose gnulib added `lib/getlocalename_l-unsafe.c` —
# a hard `#error "Please port gnulib to your platform!"` when the host isn't
# in gnulib's allowlist. cosmo isn't there yet. Until gnulib-cosmo upstream
# lands (or coreutils gates the module behind something we can disable from
# configure), 9.4 is the latest tag whose vendored gnulib compiles cleanly
# under cosmocc with just the superconfigure minimal.diff. Linux/macOS keep
# nixpkgs 9.8 (4-year version skew is small — see README).
#
# What the patch fixes (cosmocc gaps in 9.4's vendored gnulib):
#   * lib/canonicalize.c, lib/fadvise.h, src/dd.c — POSIX_FADV_* / O_*
#     used as enum initializers. cosmocc expands them to non-constant
#     expressions, so each enum init fails. The patch rewrites the
#     enums as #defines. Mirrors ahgamut/superconfigure's coreutils
#     cli/coreutils/minimal.diff verbatim.
#
# Configure overrides (mirror superconfigure's config-wrapper plus our own):
#   - ac_cv_header_error_h=no:    cosmocc has no <error.h>; without this,
#                                 if autoconf accepts a stray match,
#                                 gnulib skips its replacement and
#                                 lib/mkdir-p.c fails to find error()
#   - ac_cv_func_sethostname=yes: cosmocc exposes sethostname but
#                                 autoconf's link probe can't see it
#   - S_I[RWX]UGO defines:        GNU file-mode shortcuts cosmocc's
#                                 <sys/stat.h> doesn't ship
#
# Why we disable so much via .override:
#   - aclSupport / attrSupport: cosmo has no <sys/acl.h> / <sys/xattr.h>
#   - selinuxSupport:           libselinux is Linux-only
#   - gmpSupport:               we'd have to cosmo-build gmp; skip it and
#                               lose only `factor` / `numfmt` arb-precision
#   - withOpenssl:              md5/sha* fall back to gnulib's own
{ lib }:
final: prev:
let
  cs = import ../cosmocc.nix { pkgs = final.buildPackages; };

  coreutils94Src = final.buildPackages.fetchurl {
    url = "https://mirrors.ocf.berkeley.edu/gnu/coreutils/coreutils-9.4.tar.gz";
    hash = "sha256-X2ANkJOXOwr+JTk9m8GMRPIjJlf0yg2V6jHHAutmtzk=";
  };
in
if (prev.stdenv.hostPlatform.isCosmo or false) then {
  coreutils =
    let
      patched = (prev.coreutils.override {
        aclSupport = false;
        attrSupport = false;
        selinuxSupport = false;
        gmpSupport = false;
        withOpenssl = false;
        singleBinary = "symlinks";
      }).overrideAttrs (oa: {
        # Pin to 9.4 (see header comment). Drop nixpkgs's 9.8-targeted
        # patch set — those don't apply to 9.4 and the cosmo build needs
        # different fixes anyway.
        version = "9.4";
        src = coreutils94Src;
        patches = [ ./coreutils-cosmo.patch ];

        # nixpkgs's postPatch seds test scripts that don't exist in 9.4
        # (acl.sh landed later). We don't run tests under cosmo cross,
        # so clobber it entirely.
        postPatch = "";

        configureFlags = (oa.configureFlags or [ ]) ++ [
          "ac_cv_header_error_h=no"
          "ac_cv_func_sethostname=yes"
          "--disable-nls"
          "--disable-xattr"
          "--disable-rpath"
          "--disable-acl"
          "--disable-assert"
        ];

        env = (oa.env or { }) // {
          NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " [
            (oa.env.NIX_CFLAGS_COMPILE or "")
            "-Wno-implicit-function-declaration"
            "-DS_IXUGO=0111"
            "-DS_IRUGO=0444"
            "-DS_IWUGO=0222"
            "-DS_IRWXUGO=0777"
          ];
        };

        # ELF → PE32+ for Windows. apelink -V 4 keeps only the win32 half
        # of the polyglot header (cosmocc's single-arch cc still emits an
        # APE-eligible ELF; apelink rewrites it in-place for the target).
        # Runs in postFixup so it fires AFTER withAliases's auto-harvest
        # of the per-applet symlinks (removing the original `coreutils`
        # target would otherwise break them mid-pass).
        postFixup = (oa.postFixup or "") + ''
          ${cs.cosmocc}/bin/apelink \
            -V ${toString cs.platformBits.windows} \
            -o $out/bin/coreutils.exe \
            $out/bin/coreutils
          rm -f $out/bin/coreutils
        '';
      });
    in
    lib.withAliases final
      {
        primary = "coreutils.exe";
        aliasesFromSymlinksIn = "bin";
      }
      patched;
} else { }
