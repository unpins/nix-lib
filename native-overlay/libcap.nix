# Drop libcap's `go` nativeBuildInput (only feeds the optional Go bindings,
# unused by the static C lib). Under the unpin engine cc it actively breaks:
# `-flto` hands go's cgo self-build bitcode and `go tool dist` dies with
# `cgo: cannot parse gcc output as ELF`. Also pin GOLANG=no so the engine
# link closure never rebuilds it.
#
# autoWire = "musl": a transitive engine DEP no consumer fixes by hand, so it's
# folded into the pkgsStatic engine overlay for every linux static-musl closure
# that pulls libcap in (see mkStandaloneFlake's autoWiredFixes fold).
{ lib }:
{
  autoWire = "musl";
  apply = pkgs: pkgs.libcap.overrideAttrs (oa: {
    nativeBuildInputs = builtins.filter (x: (x.pname or "") != "go")
      (oa.nativeBuildInputs or [ ]);
    makeFlags = (oa.makeFlags or [ ]) ++ [ "GOLANG=no" ];
  });
}
