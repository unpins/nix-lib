# libidn2 ships idn2.exe; without -all-static it resolves -liconv via dll.a
# and pulls libiconv-2.dll into its closure → poisons curl transitively.
# Propagate libunistring (nixpkgs lists it plain; strictDeps consumers miss -L).
#
# postInstall: gnulib's `error` is a global in libidn2.a and collides with
# consumers defining their own (git's usage.c); localize it.
{ lib }:
self: super:
super.libidn2.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ])
    ++ [ self.libunistring ];
  postInstall = (oa.postInstall or "") + ''
    if [ -f "$out/lib/libidn2.a" ]; then
      chmod u+w "$out/lib/libidn2.a"
      $OBJCOPY --localize-symbol=error "$out/lib/libidn2.a"
    fi
  '';
})
