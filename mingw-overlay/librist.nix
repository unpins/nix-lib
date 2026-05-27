# librist cross-mingw, two fixes:
#
# 1. `+ windows.pthreads`. librist's meson check
#    `cc.has_function('pthread_create')` doesn't link winpthreads
#    in the probe, so config.h sets `HAVE_PTHREADS 0`. We need
#    winpthreads at link time anyway (mbedtls' `threading.h`
#    includes `<pthread.h>`).
#
# 2. postConfigure sed config.h: flip `HAVE_PTHREADS` and
#    `HAVE_CLOCK_GETTIME` from 0 to 1. When 0, librist's
#    `pthread-shim.h` / `time-shim.c` emit stub typedefs + decls
#    for `pthread_rwlock_*` etc. that collide with the real
#    winpthreads `<pthread.h>` / `<pthread_time.h>` (typedef widths
#    differ — shim is `int *`, real is `long long int *`).
#    winpthreads provides both, so flip the macros — shim gates
#    short-circuit to the real headers.
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
