# libaom on mingw: the CLI tools link bare `-lpthread`, absent from mingw
# libc; ffmpeg only needs `libaom.a`, so disable them. Drop the `bin`
# output too — with tools off it's empty and nixpkgs aborts on empty outputs.
{ lib }:
self: super:
super.libaom.overrideAttrs (oa: {
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DENABLE_TOOLS=OFF"
    "-DENABLE_EXAMPLES=OFF"
  ];
  outputs = builtins.filter (o: o != "bin") (oa.outputs or [ "out" ]);
  # nixpkgs moves libaom.a to $static and, when isStatic, `ln -s $static $out`
  # to stand in for $out. Without the `bin` output $out already exists, so the
  # link lands inside it and aom.pc's libdir ($out/lib) is left without the lib.
  postFixup = (oa.postFixup or "") + ''
    rm -f "$out/$(basename "$static")"
    mkdir -p "$out/lib"
    ln -s "$static/lib/libaom.a" "$out/lib/libaom.a"
  '';
})
