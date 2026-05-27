# nixpkgs librist enables tests + built_tools by default. The
# cmocka-based test sources (`srp_examples.c`, `srp_unit.c`) redefine
# `free` as `_test_free(...)` via a header pragma; cmocka 1.x +
# musl's stdlib (`__attribute_malloc__` decoration on `free`) collide
# and the test sources fail to compile. The CLI tools (`ristsender`
# `ristreceiver`) are useful as standalone programs but consumers
# linking against `librist.a` only need the library — they're dead
# weight in the build.
#
# Disable both at meson configure. Mainline `librist.a` builds clean
# once those targets are gone.
#
# On mingw, librist's meson check `cc.has_function('pthread_create')`
# misses winpthreads (it isn't on the default link line of the probe),
# so config.h leaves `HAVE_PTHREADS` undefined and `contrib/pthread-shim.h`
# emits stub typedefs + declarations of `pthread_rwlock_*` that conflict
# with the real winpthreads `<pthread.h>` definitions (typedef widths
# differ — shim ends up with `int *`, real with `long long int *`).
# Force-define HAVE_PTHREADS=1 so the shim falls through to the real
# pthread.h.
{ lib }:
pkgs:
let
  isMinGW = pkgs.stdenv.hostPlatform.isMinGW or false;
in
pkgs.librist.overrideAttrs (oa: {
  mesonFlags = (oa.mesonFlags or [ ]) ++ [
    "-Dtest=false"
    "-Dbuilt_tools=false"
  ];
  buildInputs = (oa.buildInputs or [ ])
    ++ lib.optionals isMinGW [ pkgs.windows.pthreads ];
  # `librist.pc` declares `Requires: mbedcrypto, libcjson` (public,
  # not `.private`). nixpkgs librist keeps both in `buildInputs`, so
  # consumers calling `pkg-config librist` find librist.pc but the
  # traversal of `Requires:` fails to locate `libcjson.pc`. ffmpeg's
  # version probe then reports `librist >= 0.2.7 not found`. Promote
  # to propagated so the `.pc` chain resolves for any consumer.
  propagatedBuildInputs = (oa.propagatedBuildInputs or [ ]) ++ [
    pkgs.cjson
    pkgs.mbedtls
  ];
  # meson's posix-feature probes don't link winpthreads by default on
  # mingw, so config.h sets `HAVE_PTHREADS 0` and `HAVE_CLOCK_GETTIME 0`.
  # When those are 0, librist's `pthread-shim.h` / `time-shim.c` emit
  # stub typedefs + decls that collide with the real winpthreads
  # `<pthread.h>` / `<pthread_time.h>` (transitively included via
  # mbedtls' `threading.h` and system `<time.h>`). winpthreads provides
  # both, so flip the macros post-configure — the gates short-circuit
  # to the real headers and skip emitting stubs.
  postConfigure = (oa.postConfigure or "")
    + lib.optionalString isMinGW ''
      find . -name config.h -exec sed -i \
        -e 's/#define HAVE_PTHREADS 0/#define HAVE_PTHREADS 1/' \
        -e 's/#define HAVE_CLOCK_GETTIME 0/#define HAVE_CLOCK_GETTIME 1/' \
        {} +
    '';
})
