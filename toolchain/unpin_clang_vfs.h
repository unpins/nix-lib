//===-- unpin_clang_vfs.h - embedded lib/zig tree for the in-process clang -===//
//
// The clang half of the unpins single-binary VFS. zig's own std reads are
// served by src/unpin_vfs.zig (a wrapper over the std.Io vtable), but the
// in-process clang (`zig cc`, on-demand musl libc/CRT/libc++ builds) resolves
// `#include`s and compilation INPUT paths through its OWN
// `llvm::vfs::FileSystem` (cc1), which bypasses std.Io. This exposes the same
// embedded `lib/zig` tree to clang via an llvm OverlayFileSystem.
//
//===----------------------------------------------------------------------===//

#ifndef UNPIN_CLANG_VFS_H
#define UNPIN_CLANG_VFS_H

#include "llvm/ADT/IntrusiveRefCntPtr.h"

namespace llvm {
namespace vfs {
class FileSystem;
}
} // namespace llvm

namespace unpin {

/// Virtual root prefix for the embedded tree. MUST stay byte-identical to
/// `VROOT` in src/unpin_vfs.zig — the zig half hands clang paths like
/// `VROOT/libc/include/...` (via dirRealPath → -isystem) and `VROOT/libc/musl/
/// crt/crt1.c` (compilation inputs), which must resolve in this overlay.
extern const char *const VROOT;

/// Process-wide overlay file system: `OverlayFileSystem(getRealFileSystem())`
/// with an `InMemoryFileSystem` (the embedded `lib/zig` tree, mounted at
/// `VROOT/<rel>`) pushed on top so VROOT paths win and everything else falls
/// through to the real FS. Built once, lazily, from the archive appended to
/// `/proc/self/exe` (same EOF format as pack-vfs.py / unpin_vfs.zig). If no
/// archive is present (un-packed dev build), returns the plain real FS.
llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> overlayBaseFS();

} // namespace unpin

#endif // UNPIN_CLANG_VFS_H
