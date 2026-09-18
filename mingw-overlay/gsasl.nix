# gsasl cross-mingw: build without GSSAPI, as on the static set (see
# ../native-overlay/gsasl.nix). curl only asks gsasl for SCRAM, and the
# GSSAPI/GS2 mechanisms would cross-build MIT krb5 for mingw to serve none of
# it; curl's own Kerberos on Windows goes through SSPI.
{ lib }:
self: super:
let
  notKrb5 = d: (d.pname or "") != "krb5";
in
super.gsasl.overrideAttrs (old: {
  buildInputs = lib.filter notKrb5 (old.buildInputs or [ ]);
  propagatedBuildInputs = lib.filter notKrb5 (old.propagatedBuildInputs or [ ]);
  configureFlags = lib.filter (f: !(lib.hasPrefix "--with-gssapi-impl" f)) (old.configureFlags or [ ])
    ++ [ "--with-gssapi-impl=no" "--disable-gssapi" "--disable-gs2" ];
})
