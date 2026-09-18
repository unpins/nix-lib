# gsasl's recipe builds its GSSAPI and GS2 mechanisms (Kerberos) against MIT
# krb5, and krb5 does not link under the engine (krb5kdc dies on an LTO
# `undefined symbol: malloc`). Kerberos is off in the static catalog anyway —
# curl, the consumer, documents GSS-API/Kerberos as unavailable in a static
# build. Build gsasl without it; curl only asks gsasl for SCRAM, which
# doesn't touch krb5.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    pkgs.gsasl.overrideAttrs (old: {
      buildInputs = lib.filter (d: (d.pname or "") != "krb5") (old.buildInputs or [ ]);
      propagatedBuildInputs = lib.filter (d: (d.pname or "") != "krb5") (old.propagatedBuildInputs or [ ]);
      configureFlags = lib.filter (f: !(lib.hasPrefix "--with-gssapi-impl" f)) (old.configureFlags or [ ])
        ++ [ "--with-gssapi-impl=no" "--disable-gssapi" "--disable-gs2" ];
    });
}
