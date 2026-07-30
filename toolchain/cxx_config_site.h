//===----------------------------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// M4: the generated libc++ site configuration. Upstream's CMake produces this
// from include/__config_site.in by substituting the build's knobs; we resolve
// it once, for our fixed configuration (static, threaded, ABI v1, musl libc,
// hardening off). It is embedded in the VFS at cxx/libcxx/include/__config_site
// so the UNPATCHED upstream __config (`#include <__config_site>`) works for both
// the on-demand libc++/libc++abi build AND user C++ compiles — no header patch
// (cf. zig, which instead guts __config and passes a -D wall on every compile).
// Values mirror zig 0.16's libcxx.zig addCxxArgs() for an aarch64/x86_64/riscv64
// linux-musl, threaded, ReleaseSmall target. Build-only macros (NDEBUG,
// _LIBCPP_BUILDING_LIBRARY, the *_DISABLE_VISIBILITY_ANNOTATIONS pair, …) are
// NOT here — they are passed as -D only while compiling the runtime objects.
//
//===----------------------------------------------------------------------===//

#ifndef _LIBCPP___CONFIG_SITE
#define _LIBCPP___CONFIG_SITE

#define _LIBCPP_ABI_VERSION 1
#define _LIBCPP_ABI_NAMESPACE __1
#define _LIBCPP_ABI_FORCE_ITANIUM 0
#define _LIBCPP_ABI_FORCE_MICROSOFT 0
#define _LIBCPP_HAS_THREADS 1
#define _LIBCPP_HAS_MONOTONIC_CLOCK 1
#define _LIBCPP_HAS_TERMINAL 1
#define _LIBCPP_HAS_MUSL_LIBC 1
#define _LIBCPP_HAS_THREAD_API_PTHREAD 1
#define _LIBCPP_HAS_THREAD_API_EXTERNAL 0
#define _LIBCPP_HAS_THREAD_API_WIN32 0
#define _LIBCPP_HAS_THREAD_API_C11 0 // FIXME: Is this guarding dead code?
/* #undef _LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS */ // build-only -D
#define _LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS 0
/* #undef _LIBCPP_NO_VCRUNTIME */
/* #undef _LIBCPP_TYPEINFO_COMPARISON_IMPLEMENTATION */
#define _LIBCPP_HAS_FILESYSTEM 1
#define _LIBCPP_HAS_RANDOM_DEVICE 1
#define _LIBCPP_HAS_LOCALIZATION 1
#define _LIBCPP_HAS_UNICODE 1
#define _LIBCPP_HAS_WIDE_CHARACTERS 1
#define _LIBCPP_HAS_NO_STD_MODULES
// 0, matching the win/darwin config sites: the tzdb TUs live in
// libc++experimental.a, which we do not build, and std::chrono::tzdb reads
// /usr/share/zoneinfo/tzdata.zi at runtime — a host file a hermetic static
// binary must not depend on. Claiming 1 while shipping neither was the
// inconsistency; the API is unreachable without -fexperimental-library either way.
#define _LIBCPP_HAS_TIME_ZONE_DATABASE 0
#define _LIBCPP_INSTRUMENTED_WITH_ASAN 0

// PSTL backends
#define _LIBCPP_PSTL_BACKEND_SERIAL
/* #undef _LIBCPP_PSTL_BACKEND_STD_THREAD */
/* #undef _LIBCPP_PSTL_BACKEND_LIBDISPATCH */

// Hardening.
#define _LIBCPP_HARDENING_MODE_DEFAULT _LIBCPP_HARDENING_MODE_NONE

#endif // _LIBCPP___CONFIG_SITE
