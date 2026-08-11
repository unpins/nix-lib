# opusfile on mingw: propagate openssl.
#
# opusfile links https:// streams through OpenSSL and says so in its `.pc`
# as `Requires.private: openssl` — a channel pkg-config only emits under
# `--static`, and one nothing on the consumer side reads. nixpkgs puts
# openssl in plain buildInputs, so it stops at opusfile's own link.
#
# The mega link needs the archive itself: `multicallExternalDepDirs` walks
# the standalone's own buildInputs ++ propagatedBuildInputs, then only
# propagatedBuildInputs transitively, and globs `<dir>/lib/*.a`. openssl
# sitting one buildInputs hop down is invisible there, so opus-tools' fold
# came up undefined on `SSL_set_connect_state`. Propagating puts libssl.a
# and libcrypto.a in the glob's reach, which is what a static consumer of
# opusfile needs anyway.
{ lib }:
self: super:
super.opusfile.overrideAttrs (oa: {
  buildInputs = builtins.filter (d: (d.pname or "") != "openssl") (oa.buildInputs or [ ]);
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [ self.openssl ];
})
