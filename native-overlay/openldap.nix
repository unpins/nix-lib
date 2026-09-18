# openldap's Cyrus SASL support only serves its own client tools and slapd:
# curl, the one consumer, speaks SASL itself and only calls the raw
# `ldap_sasl_bind`, which libldap has without Cyrus. Linked in, it costs a
# static libsasl2 whose Berkeley DB/libcrypto references the configure probe
# can't see, and the tools then fail to link under the engine
# (`undefined symbol: malloc` from cyrus-sasl's common.c, the same LTO
# failure krb5 hits). Build without it; `--enable-spasswd` needs SASL.
{ lib }:
let
  notSasl = d: (d.pname or "") != "cyrus-sasl";
in
{
  autoWire = "static";
  apply = pkgs:
    pkgs.openldap.overrideAttrs (old: {
      buildInputs = lib.filter notSasl (old.buildInputs or [ ]);
      propagatedBuildInputs = lib.filter notSasl (old.propagatedBuildInputs or [ ]);
      configureFlags = lib.filter (f: f != "--enable-spasswd") (old.configureFlags or [ ])
        ++ [ "--without-cyrus-sasl" ];
    });
}
