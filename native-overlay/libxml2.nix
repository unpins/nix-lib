# libxml2 bakes $sysconfdir into the library as XML_SYSCONFDIR, and that is
# where it looks for the default XML and SGML catalogs (catalog.c,
# xmlcatalog.c) — and what `xmllint --help` prints back to the user. nixpkgs
# leaves sysconfdir at $out/etc, so every engine consumer of libxml2 shipped a
# binary carrying `/nix/store/…-libxml2-…/etc/xml/catalog`: a default catalog
# that exists on no user's machine, and a store path the artifact has no
# business quoting. Measured in the published x86_64-linux artifacts of
# xmllint, chafa, avif and biber.
#
# Nothing is installed into sysconfdir (no sysconf_DATA anywhere in the tree),
# so retargeting it costs nothing. /etc is where every distribution puts these,
# and XML_CATALOG_FILES still overrides it at runtime. Same shape as the
# openssl /etc/ssl retarget; the Windows C:/etc variant is the mingw overlay's
# job.
#
# autoWire "static": valid on linux-static and darwin alike.
{ lib }:
{
  autoWire = "static";
  apply = pkgs: pkgs.libxml2.overrideAttrs (oa: {
    configureFlags = (oa.configureFlags or [ ]) ++ [ "--sysconfdir=/etc" ];
  });
}
