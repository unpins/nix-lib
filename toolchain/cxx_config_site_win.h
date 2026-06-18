//===----------------------------------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// The libc++ site configuration for *-windows-gnu (mingw-w64). Same role as
// cxx_config_site.h (the musl/linux one), resolved for a Windows target. It is
// embedded at cxx/win/__config_site and that dir is placed on the include path
// BEFORE cxx/libcxx/include for every Windows C++ compile (runtime build + user
// front), so `#include <__config_site>` resolves here instead of the musl copy.
//
// Only four knobs differ from the musl config, mirroring zig 0.16's
// libcxx.zig addCxxArgs() for a windows-gnu target:
//   - _LIBCPP_HAS_MUSL_LIBC          1 -> 0  (UCRT, not musl)
//   - _LIBCPP_HAS_THREAD_API_PTHREAD 1 -> 0  } win32 thread API (thread_win32.cpp),
//   - _LIBCPP_HAS_THREAD_API_WIN32   0 -> 1  } not winpthreads
//   - _LIBCPP_HAS_TIME_ZONE_DATABASE 1 -> 0  (zig sets tzdb only on linux)
// Everything else matches the musl config (ABI v1, threaded, hardening off).
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
#define _LIBCPP_HAS_MUSL_LIBC 0
#define _LIBCPP_HAS_THREAD_API_PTHREAD 0
#define _LIBCPP_HAS_THREAD_API_EXTERNAL 0
#define _LIBCPP_HAS_THREAD_API_WIN32 1
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
#define _LIBCPP_HAS_TIME_ZONE_DATABASE 0
#define _LIBCPP_INSTRUMENTED_WITH_ASAN 0

// PSTL backends
#define _LIBCPP_PSTL_BACKEND_SERIAL
/* #undef _LIBCPP_PSTL_BACKEND_STD_THREAD */
/* #undef _LIBCPP_PSTL_BACKEND_LIBDISPATCH */

// Hardening.
#define _LIBCPP_HARDENING_MODE_DEFAULT _LIBCPP_HARDENING_MODE_NONE

#endif // _LIBCPP___CONFIG_SITE
