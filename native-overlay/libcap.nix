# Drop libcap's `go` nativeBuildInput (only feeds the optional Go bindings,
# unused by the static C lib). Under the unpin engine cc it actively breaks:
# `-flto` hands go's cgo self-build bitcode and `go tool dist` dies with
# `cgo: cannot parse gcc output as ELF`. Also pin GOLANG=no so the engine
# link closure never rebuilds it.
{ lib }:
scope:
scope.libcap.overrideAttrs (oa: {
  nativeBuildInputs = builtins.filter (x: (x.pname or "") != "go")
    (oa.nativeBuildInputs or [ ]);
  makeFlags = (oa.makeFlags or [ ]) ++ [ "GOLANG=no" ];
})
