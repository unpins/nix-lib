# Three things upstream nixpkgs doesn't do for jq on mingw:
# - winpthreads in buildInputs (mingw-w64 ships it separately; jq #includes <pthread.h>).
# - LDFLAGS=-all-static: windows.pthreads ships .a + .dll.a; without it libtool picks
#   .dll.a and the DLL-link hook copies libwinpthread.dll next to jq.exe.
# - postFixup: nixpkgs jq.nix hard-codes `$bin/bin/jq`; on mingw it's jq.exe.
{ lib }:
pkgs:
let cross = lib.mingwStaticCross pkgs; in
cross.jq.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ cross.windows.pthreads ];
  makeFlags = (old.makeFlags or [ ]) ++ [ "LDFLAGS=-all-static" ];
  postFixup = ''
    remove-references-to \
      -t "$dev" -t "$man" -t "$doc" \
      "$bin/bin/jq.exe"
  '';
})
