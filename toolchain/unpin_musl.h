//===-- unpin_musl.h - on-demand musl sysroot + driver front --------------===//
//
// The unpins LLVM suite ships ONE static binary that is a complete cross
// C/C++ toolchain. For a `*-linux-musl` target, the musl libc.a + CRT objects
// are built ON DEMAND from sources embedded in the in-binary VFS (the same
// /proc/self/exe zstd-zip the clang resource dir lives in, see
// unpin_clang_vfs / unpin_vfs_core), cached under $XDG_CACHE_HOME/unpin-llvm.
//
// frontRewriteMusl() is the driver "front": called at the very top of
// clang_main (clang/tools/driver/driver.cpp), it inspects the user's argv,
// and for a musl target rewrites it to compile against the embedded musl
// headers and link against the on-demand sysroot. A no-op for everything else
// (native builds, -cc1/-cc1as sub-tools, and the builder's own re-execs, which
// set UNPIN_NO_FRONT=1).
//
//===----------------------------------------------------------------------===//
#pragma once

#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/StringSaver.h"

namespace unpin {

// Inspect/rewrite the clang driver argv for an on-demand musl target. Mutates
// `Args` in place; injected C-strings are interned in `Saver` for lifetime.
void frontRewriteMusl(llvm::SmallVectorImpl<const char *> &Args,
                      llvm::StringSaver &Saver);

} // namespace unpin
