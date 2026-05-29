# pkgsStatic.libjxl: build just the library — drop plugins, docs, tools.
#
# Two things break a transitive static libjxl as nixpkgs configures it:
#   1. `enablePlugins = true` builds the GDK/GIMP loader modules (shared
#      objects) — they can't link under musl-static (the usual crtbeginT.o
#      `__TMC_END__` relocation), and their postInstall gdk-pixbuf cache
#      step is meaningless for a static lib. `.override { enablePlugins =
#      false; }` removes both.
#   2. `depsBuildBuild = [ graphviz ]` feeds doxygen's diagram generator.
#      graphviz pulls gd, which fails to link in this build env, and nix
#      realizes the input even when docs are off. Drop it and turn the doc/
#      manpage/benchmark/example/tool/test switches off so nothing wants it.
#
# Leaves libjxl + libjxl_threads (what the chafa JXL loader links) with the
# brotli/highway/lcms2 deps intact.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  # asciidoc/doxygen everywhere (docs off); gdk-pixbuf + make-shell-wrapper-hook
  # only on mingw — they survive `enablePlugins = false` in nativeBuildInputs,
  # and the wrapper hook splices to a mingw bash that can't cross-compile
  # (`unknown type name 'sigset_t'`). Same trap as libavif. Gated to mingw to
  # keep native/darwin libjxl's cached closure.
  dropNative = lib.filter
    (x: !(builtins.elem (x.pname or x.name or "")
      ([ "asciidoc" "doxygen" ] ++ lib.optionals isMinGW [ "gdk-pixbuf" "make-shell-wrapper-hook" ])));
  # libjxl's buildInputs are mostly cjxl/djxl tool I/O + benchmark/test deps,
  # unused by the core encode/decode lib (tools/benchmark/test all off above).
  #   - gperftools (tcmalloc): drop everywhere — its arch-specific stack
  #     unwinder fails to build on more than one target (mingw's Windows
  #     patch_functions.cc; powerpc64le's stacktrace_unittest), and it only
  #     ever fed the benchmark harness.
  #   - the rest (gtest/giflib/libjpeg/libpng/libwebp/gdk-pixbuf/openexr) cross
  #     fine on the native arches, so only drop them on mingw (where the whole
  #     set is dead weight) to keep the other arches' cached closures.
  # The core lib keeps lcms2 + zlib (brotli/highway stay propagated).
  toolingDrops = [ "gperftools" ]
    ++ lib.optionals isMinGW
    [ "gtest" "giflib" "libjpeg-turbo" "libpng-apng" "libwebp" "gdk-pixbuf" "openexr" ];
  dropTooling = lib.filter (x: !(builtins.elem (x.pname or x.name or "") toolingDrops));
in
(pkgs.libjxl.override { enablePlugins = false; }).overrideAttrs (oa: {
  depsBuildBuild = [ ];
  nativeBuildInputs = dropNative (oa.nativeBuildInputs or [ ]);
  # pkgsStatic auto-promotes buildInputs → propagatedBuildInputs, so a dep
  # dropped only from buildInputs survives via the propagated list (gperftools
  # then still builds and fails on ppc64le/riscv). Filter both.
  # See [[feedback_pkgsstatic_propagated_buildinputs]].
  buildInputs = dropTooling (oa.buildInputs or [ ]);
  propagatedBuildInputs = dropTooling (oa.propagatedBuildInputs or [ ]);
  cmakeFlags = (oa.cmakeFlags or [ ]) ++ [
    "-DJPEGXL_ENABLE_DOXYGEN=OFF"
    "-DJPEGXL_ENABLE_MANPAGES=OFF"
    "-DJPEGXL_ENABLE_BENCHMARK=OFF"
    "-DJPEGXL_ENABLE_EXAMPLES=OFF"
    "-DJPEGXL_ENABLE_TOOLS=OFF"
    "-DBUILD_TESTING=OFF"
  ]
  # cross-darwin static: pkgsStatic sets -DCMAKE_LINK_SEARCH_START_STATIC=ON,
  # which makes every CMake try-link probe link statically. darwin has no
  # static libSystem, so the probes that *link* an executable fail and the
  # REQUIRED find_package() aborts. Both affected probes have a known-true
  # answer on x86_64 darwin, so pre-seed the cache var each keys on — CMake
  # then skips the broken link probe:
  #   - FindThreads: pthreads live in libSystem (no lib flag) → Threads_FOUND
  #     with an empty CMAKE_THREAD_LIBS_INIT.
  #   - FindAtomics: x86_64 has lock-free atomic instructions → no -latomic.
  # (This `cmakeFlags` append can't just flip LINK_SEARCH_START_STATIC off:
  # pkgsStatic appends its flag after ours, so its ON wins; the cache pre-seed
  # sidesteps the probe entirely.)
  ++ lib.optionals isDarwin [
    "-DCMAKE_HAVE_LIBC_PTHREAD=ON"
    "-DATOMICS_LOCK_FREE_INSTRUCTIONS=ON"
  ];
  doCheck = false;
})
