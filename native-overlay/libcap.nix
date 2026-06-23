# libcap's sole nativeBuildInput is `go`, pulled only to build its optional
# Go bindings (the `GOLANG` knob); the static C library (libcap.a/libpsx.a)
# never ships them. Left in, go is dead weight — and under the unpin engine cc
# it actively breaks: go's cgo self-build introspects the object format it gets
# back, but `-flto` hands it bitcode, so `go tool dist` dies with `cgo: cannot
# parse gcc output as ELF`. go is unique among build tools here (the rest link
# to runnable ELF and tolerate the engine). Strip the go input and pin
# GOLANG=no so the engine link closure (coreutils → libcap) never builds it.
{ lib }:
scope:
scope.libcap.overrideAttrs (oa: {
  nativeBuildInputs = builtins.filter (x: (x.pname or "") != "go")
    (oa.nativeBuildInputs or [ ]);
  makeFlags = (oa.makeFlags or [ ]) ++ [ "GOLANG=no" ];
})
