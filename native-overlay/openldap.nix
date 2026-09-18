# curl is the one consumer, and it links the client library alone
# (libldap + liblber). Two parts of the default build stand in its way under
# the engine, and neither reaches the binary:
#
# - Cyrus SASL. curl speaks SASL itself and only calls the raw
#   `ldap_sasl_bind`, which libldap has without Cyrus. Linked in, it costs a
#   static libsasl2 whose Berkeley DB/libcrypto references the configure probe
#   can't see, and openldap's own tools then fail to link (`undefined symbol:
#   malloc` from cyrus-sasl's common.c, the same LTO failure krb5 hits).
#   `--enable-spasswd` needs SASL.
# - The slapd server. Its overlays are combined with a bare `ld -r`, which
#   ld64.lld refuses on darwin ("must specify -arch"). `--disable-slapd` drops
#   the server with its overlay/crypt options, the recipe's contrib slapd
#   modules, and the test suite, which exercises slapd; nothing is left in
#   `$out/var` for preFixup to remove.
{ lib }:
let
  notSasl = d: (d.pname or "") != "cyrus-sasl";
  slapdOnly = [ "--enable-spasswd" "--enable-overlays" "--enable-crypt" ];
in
{
  autoWire = "static";
  apply = pkgs:
    pkgs.openldap.overrideAttrs (old: {
      buildInputs = lib.filter notSasl (old.buildInputs or [ ]);
      propagatedBuildInputs = lib.filter notSasl (old.propagatedBuildInputs or [ ]);
      configureFlags = lib.filter (f: !(builtins.elem f slapdOnly)) (old.configureFlags or [ ])
        ++ [ "--without-cyrus-sasl" "--disable-slapd" ];
      extraContribModules = [ ];
      doCheck = false;
      preFixup = ''
        rm -rf $out/var
      '';
    });
}
