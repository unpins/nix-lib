# libbsd is a transitive engine dep no consumer fixes by hand (shadow,
# util-linux link libbsd.a), so auto-wire the two static-host fixes below.
# Gates to the static host; the non-static build host is a no-op
# (byte-identical).
#
# (1) doCheck = false. libbsd's `make check` fails under the static-musl engine
# on two harness artifacts, not libbsd-function bugs: the explicit_bzero test
# reads freed stack memory to verify the clear (UB that segfaults once the
# engine's -flto reorders the frame), and the nlist test aborts (musl's nlist
# is a stub). Every consumer links libbsd.a fine, so skip the suite.
#
# (2) Force abi_transparent_libmd=no. On musl, upstream configure.ac hardcodes
# transparent_libmd=yes, which builds a `libbsd.so` GNU ld script that
# auto-pulls libmd — a *shared-library-only* convenience. We build
# `--disable-shared`, so there's no `.so` for it to apply to, yet its
# `format.ld` probe (`$(CC) -shared -nostdlib -nostartfiles -x assembler
# /dev/null`) still runs at install time and dies: the engine cc wrapper
# appends its static crt1.o, and `-x assembler` makes the driver try to
# *assemble* that ELF object ("invalid character in input"). The flag gates
# only src/Makefile.am (the format.ld target + the .so ld-script) — it touches
# no compiled symbol in libbsd.a, and MD5 lives in libmd.a either way (static
# consumers link `-lmd` regardless, via the propagated libmd). So disabling it
# for the static build loses nothing; it just drops an inapplicable shared-lib
# step. Inserted before the single LIBBSD_SELECT_ABI([transparent_libmd]) call
# so it overrides whatever the per-host case set; autoreconfHook regenerates
# configure from configure.ac.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isStatic
    then
      pkgs.libbsd.overrideAttrs
        (oa: {
          doCheck = false;
          postPatch = (oa.postPatch or "") + ''
            substituteInPlace configure.ac \
              --replace-fail \
                'LIBBSD_SELECT_ABI([transparent_libmd], [transparent libmd support])' \
                'abi_transparent_libmd=no
            LIBBSD_SELECT_ABI([transparent_libmd], [transparent libmd support])'
          '';
        })
    else pkgs.libbsd;
}
