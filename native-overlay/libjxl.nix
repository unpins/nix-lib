# pkgsStatic.libjxl: build just the library — drop plugins, docs, tools.
# Leaves libjxl + libjxl_threads (the chafa JXL loader's link) with
# brotli/highway/lcms2 intact.
#
#   1. enablePlugins=false: the GDK/GIMP loader modules are shared objects
#      that can't link under musl-static (crtbeginT.o `__TMC_END__`).
#   2. drop depsBuildBuild graphviz (doxygen's diagram generator): pulls gd,
#      which fails to link here, and nix realizes it even with docs off.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isEngine = lib.hasInfix "unpin-cc" (pkgs.stdenv.cc.name or "");
  # asciidoc/doxygen everywhere (docs off); gdk-pixbuf + make-shell-wrapper-hook
  # only on mingw — they survive enablePlugins=false, and the wrapper hook
  # splices to a mingw bash that can't cross-compile (no sigset_t). Same trap
  # as libavif. Gated to mingw to keep native/darwin's cached closure.
  dropNative = lib.filter
    (x: !(builtins.elem (x.pname or x.name or "")
      ([ "asciidoc" "doxygen" ] ++ lib.optionals isMinGW [ "gdk-pixbuf" "make-shell-wrapper-hook" ])));
  # buildInputs are mostly cjxl/djxl tool + benchmark/test deps, unused by the
  # core lib (all off above). Core keeps lcms2 + zlib (brotli/highway stay
  # propagated).
  #   - gperftools: drop everywhere — its arch-specific stack unwinder fails to
  #     build on multiple targets (mingw, ppc64le), only fed the benchmark.
  #   - the rest cross fine on native arches, so drop only on mingw (where the
  #     whole set is dead weight) to keep other arches' cached closures.
  toolingDrops = [ "gperftools" ]
    ++ lib.optionals isMinGW
    [ "gtest" "giflib" "libjpeg-turbo" "libpng-apng" "libwebp" "gdk-pixbuf" "openexr" ];
  dropTooling = lib.filter (x: !(builtins.elem (x.pname or x.name or "") toolingDrops));
in
(pkgs.libjxl.override { enablePlugins = false; }).overrideAttrs (oa: {
  depsBuildBuild = [ ];
  nativeBuildInputs = dropNative (oa.nativeBuildInputs or [ ]);
  # pkgsStatic auto-promotes buildInputs → propagated, so filter both or the
  # drop survives. See [[feedback_pkgsstatic_propagated_buildinputs]].
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
  # cross-darwin static: pkgsStatic's -DCMAKE_LINK_SEARCH_START_STATIC=ON makes
  # every try-link probe link statically, but darwin has no static libSystem so
  # link-probing REQUIRED find_package()s abort. Pre-seed the cache var each
  # keys on (known-true on x86_64 darwin) so CMake skips the broken probe:
  #   - FindThreads: pthreads live in libSystem (no lib flag).
  #   - FindAtomics: x86_64 has lock-free atomics → no -latomic.
  # Can't just flip LINK_SEARCH_START_STATIC off — pkgsStatic appends its ON
  # after ours and wins; the pre-seed sidesteps the probe.
  ++ lib.optionals isDarwin [
    "-DCMAKE_HAVE_LIBC_PTHREAD=ON"
    "-DATOMICS_LOCK_FREE_INSTRUCTIONS=ON"
  ];
  # nixpkgs pins `CXXFLAGS = -mfp16-format=ieee` on aarch32 (gcc defaults to
  # `none`, which hides `__fp16`). clang has no such option — it is always IEEE
  # — and rejects it outright, so CMake's first try-compile dies. Only the
  # engine path sees clang; gcc still needs the flag. Same fix the jxl flake
  # carries for its own top-level libjxl.
  env = (oa.env or { })
    // lib.optionalAttrs (isEngine && pkgs.stdenv.hostPlatform.isAarch32) { CXXFLAGS = ""; };
  doCheck = false;
})
