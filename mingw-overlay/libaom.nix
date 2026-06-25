# libaom on mingw: the CLI tools link bare `-lpthread`, absent from mingw
# libc; ffmpeg only needs `libaom.a`, so disable them. Drop the `bin`
# output too — with tools off it's empty and nixpkgs aborts on empty outputs.
{ lib }:
self: super:
super.libaom.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DENABLE_TOOLS=OFF"
    "-DENABLE_EXAMPLES=OFF"
  ];
  outputs = builtins.filter (o: o != "bin") (old.outputs or [ "out" ]);
})
