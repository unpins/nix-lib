# libaom on mingw: tools (aomdec.exe / aomenc.exe) link with bare
# `-lpthread` which mingw's libc doesn't carry — winpthreads lives
# under `windows.pthreads`. ffmpeg's `--enable-libaom` only needs
# `libaom.a`, not the CLI codec tools, so disable them via cmake.
# Drop the `bin` output too — nothing lands there with tools off
# and nixpkgs aborts if a declared output produces no path.
{ lib }:
self: super:
super.libaom.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DENABLE_TOOLS=OFF"
    "-DENABLE_EXAMPLES=OFF"
  ];
  outputs = builtins.filter (o: o != "bin") (old.outputs or [ "out" ]);
})
