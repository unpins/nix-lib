# libidn2 ships idn2.exe. Without -all-static, idn2.exe resolves -liconv via
# dll.a and pulls libiconv-2.dll into its closure → poisons curl transitively.
# Also propagate libunistring (nixpkgs lists it as plain buildInput; strictDeps
# consumers don't see -L).
#
# postInstall: gnulib's `error` is exported as a global from libidn2.a and
# collides with consumers that define their own `error` (git's usage.c).
# Localize it so it stays internal to the archive; libidn2's own callers
# still resolve to their now-local copy.
{ lib }:
self: super:
super.libidn2.overrideAttrs (old: {
  makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ])
    ++ [ self.libunistring ];
  postInstall = (old.postInstall or "") + ''
    if [ -f "$out/lib/libidn2.a" ]; then
      chmod u+w "$out/lib/libidn2.a"
      $OBJCOPY --localize-symbol=error "$out/lib/libidn2.a"
    fi
  '';
})
