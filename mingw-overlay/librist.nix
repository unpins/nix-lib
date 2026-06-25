# librist cross-mingw, two fixes:
#
# 1. `+ windows.pthreads` — needed at link time anyway (mbedtls'
#    `threading.h` includes `<pthread.h>`); librist's meson probe doesn't
#    link it, so config.h gets `HAVE_PTHREADS 0`.
#
# 2. postConfigure flips `HAVE_PTHREADS`/`HAVE_CLOCK_GETTIME` 0→1 — at 0,
#    librist's pthread/time shims emit stub typedefs that collide with
#    real winpthreads headers (width mismatch: shim `int *` vs real
#    `long long int *`). winpthreads provides both; the macros gate the shim.
{ lib }:
self: super:
super.librist.overrideAttrs (oa: {
  buildInputs = (oa.buildInputs or [ ]) ++ [ self.windows.pthreads ];
  postConfigure = (oa.postConfigure or "") + ''
    find . -name config.h -exec sed -i \
      -e 's/#define HAVE_PTHREADS 0/#define HAVE_PTHREADS 1/' \
      -e 's/#define HAVE_CLOCK_GETTIME 0/#define HAVE_CLOCK_GETTIME 1/' \
      {} +
  '';
})
