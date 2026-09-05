# Windows half of the sysconfdir retarget (see native-overlay/libxml2.nix):
# without it the `.exe` carries the libxml2 store path as its default XML/SGML
# catalog. Windows has no /etc, so the catalogs land under C:/etc — the same
# shape as the C:/ssl the openssl package uses for the same reason.
# XML_CATALOG_FILES overrides it either way.
{ lib }:
self: super:
super.libxml2.overrideAttrs (oa: {
  configureFlags = (oa.configureFlags or [ ]) ++ [ "--sysconfdir=C:/etc" ];
})
