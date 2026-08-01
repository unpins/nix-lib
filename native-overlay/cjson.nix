# darwin only: cjson's CMake turns on its own `-Wall -Wextra -Werror` block
# (ENABLE_CUSTOM_COMPILER_FLAGS, default ON). On darwin the engine builds the
# whole set with the unpin clang, and pkgsStatic injects `NIX_CFLAGS_LINK=
# " -static-libgcc"` — valid on Linux, inert on darwin (no libgcc; compiler-rt
# and libSystem instead). cjson's tests/demos compile and link in ONE clang
# invocation, so the wrapper appends that link flag to a compile step and clang
# reports `argument unused during compilation: '-static-libgcc'`, which -Werror
# turns fatal. Drop cjson's strict-flag block; the warnings are its own and the
# library object we link is unaffected.
#
# Third consumer to need this (librist, srt, ffmpeg), so it lives here rather
# than being copied into each flake again. Gated on darwin so linux/cross
# derivations keep their hashes. `autoWire = "static"` — NOT "musl": darwin's
# pkgsStatic is static but not musl, so the musl gate never fires there.
{ lib }:
{
  autoWire = "static";
  apply = pkgs:
    if pkgs.stdenv.hostPlatform.isDarwin then
      pkgs.cjson.overrideAttrs
        (oa: {
          cmakeFlags = (oa.cmakeFlags or [ ]) ++ [ "-DENABLE_CUSTOM_COMPILER_FLAGS=OFF" ];
        })
    else
      pkgs.cjson;
}
