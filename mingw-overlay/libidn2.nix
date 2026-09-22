# libidn2 ships idn2.exe; without -all-static it resolves -liconv via dll.a
# and pulls libiconv-2.dll into its closure → poisons curl transitively.
# Propagate libunistring (nixpkgs lists it plain; strictDeps consumers miss -L).
#
# gnulib's `error` is a global in libidn2.a and collides with consumers
# defining their own (git's usage.c). Non-engine: localize it in the archive.
# Engine: the members are LLVM bitcode, which `llvm-objcopy` rejects (`not
# recognized as a valid object file`), so have gnulib spell it `rpl_error` at
# the source instead — the "future OS version" answer is gnulib's own switch
# for its replacement module.
{ lib }:
self: super:
super.libidn2.overrideAttrs (oa: {
  makeFlags = (oa.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ])
    ++ [ self.libunistring ];
} // (if lib.isUnpinEngine self then {
  configureFlags = (oa.configureFlags or [ ])
    ++ [ "gl_cv_onwards_func_error=future OS version" ];
} else {
  postInstall = (oa.postInstall or "") + ''
    if [ -f "$out/lib/libidn2.a" ]; then
      chmod u+w "$out/lib/libidn2.a"
      $OBJCOPY --localize-symbol=error "$out/lib/libidn2.a"
    fi
  '';
}))
