//===-- unpin_clang_vfs.cpp - embedded lib/zig tree for in-process clang ---===//
//
// See unpin_clang_vfs.h. The clang half of the single-binary VFS. It exposes
// the embedded lib/zig tree (a zstd-in-zip overlay appended to the executable)
// to clang's file lookups via an llvm OverlayFileSystem.
//
// Unlike the previous flat-archive version, entries are zstd-compressed, so we
// can't hand clang non-owning views into the image. Instead this is a *lazy*
// llvm::vfs::FileSystem: status/dir_begin answer straight from the C reader's
// node table (no decompression), and a file's bytes are inflated on first
// openFileForRead/getBuffer and cached for the process lifetime by the shared
// reader (unpin_vfs_core.c — the same reader the zig half uses). A `zig cc`
// that touches a few dozen of the ~20k entries never inflates the rest.
//
//===----------------------------------------------------------------------===//

#include "unpin_clang_vfs.h"
#include "unpin_vfs_core.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Errc.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/VirtualFileSystem.h"

#include <cstring>
#include <ctime>
#include <string>

namespace unpin {
// Keep in sync with unpin_vfs.zig:VROOT.
const char *const VROOT = "/__unpin_ziglib__";
} // namespace unpin

namespace {

namespace vfs = llvm::vfs;
using llvm::StringRef;

constexpr size_t kVrootLen = 17; // strlen("/__unpin_ziglib__")

// Map a requested VFS path to a lib-relative path under VROOT. Returns true and
// sets `rel` (no leading/trailing slash; "" = root) when `path` is under VROOT;
// false otherwise (the OverlayFileSystem then falls through to the real FS).
bool toRel(StringRef path, StringRef &rel) {
  if (!path.starts_with(unpin::VROOT))
    return false;
  StringRef rest = path.drop_front(kVrootLen);
  if (rest.empty()) { // exactly VROOT → the root
    rel = StringRef();
    return true;
  }
  if (rest.front() != '/')
    return false; // e.g. "/__unpin_ziglib__x" — not ours
  rest = rest.drop_front(1);
  while (rest.ends_with("/"))
    rest = rest.drop_back(1);
  rel = rest;
  return true;
}

vfs::Status statusFor(size_t idx, StringRef name, bool isDir, uint64_t size) {
  using namespace llvm::sys::fs;
  return vfs::Status(name, UniqueID(1, idx),
                     llvm::sys::TimePoint<>(std::chrono::seconds(0)),
                     /*User=*/0, /*Group=*/0, size,
                     isDir ? file_type::directory_file : file_type::regular_file,
                     isDir ? perms::all_all : perms::all_read);
}

// A lazily-inflated file. The reader owns the (cached) decompressed buffer for
// the process lifetime, so the MemoryBuffer is a non-owning view; the reader
// guarantees a trailing NUL, satisfying RequiresNullTerminator.
class ZipFile : public vfs::File {
  size_t Idx;
  std::string Name;
  bool IsDir;
  uint64_t Size;

public:
  ZipFile(size_t Idx, StringRef Name, bool IsDir, uint64_t Size)
      : Idx(Idx), Name(Name.str()), IsDir(IsDir), Size(Size) {}

  llvm::ErrorOr<vfs::Status> status() override {
    return statusFor(Idx, Name, IsDir, Size);
  }

  llvm::ErrorOr<std::unique_ptr<llvm::MemoryBuffer>>
  getBuffer(const llvm::Twine &Name, int64_t /*FileSize*/,
            bool RequiresNullTerminator, bool /*IsVolatile*/) override {
    uint64_t len = 0;
    const void *data = unpin_vfs_data(Idx, &len);
    if (!data)
      return llvm::errc::io_error;
    return llvm::MemoryBuffer::getMemBuffer(
        StringRef(static_cast<const char *>(data), len), Name.str(),
        RequiresNullTerminator);
  }

  std::error_code close() override { return {}; }
};

// True iff lib-relative `child` is a direct child of directory `parent`.
bool isDirectChild(StringRef parent, StringRef child) {
  if (child.empty())
    return false;
  if (parent.empty())
    return !child.contains('/');
  if (!child.starts_with(parent) || child.size() <= parent.size() + 1 ||
      child[parent.size()] != '/')
    return false;
  return !child.drop_front(parent.size() + 1).contains('/');
}

class ZipDirIter : public vfs::detail::DirIterImpl {
  std::string Parent; // lib-relative dir whose children we enumerate
  size_t Cursor;

public:
  ZipDirIter(StringRef Parent, std::error_code &EC)
      : Parent(Parent.str()), Cursor(0) {
    EC = increment();
  }

  std::error_code increment() override {
    size_t n = unpin_vfs_count();
    for (; Cursor < n; ++Cursor) {
      const char *p = nullptr;
      size_t plen = 0;
      int isDir = 0;
      uint64_t size = 0;
      if (unpin_vfs_entry(Cursor, &p, &plen, &isDir, &size) != 0)
        continue;
      StringRef childRel(p, plen);
      if (!isDirectChild(Parent, childRel))
        continue;
      llvm::SmallString<256> full(unpin::VROOT);
      full += '/';
      full += childRel;
      CurrentEntry = vfs::directory_entry(
          std::string(full), isDir ? llvm::sys::fs::file_type::directory_file
                                   : llvm::sys::fs::file_type::regular_file);
      ++Cursor; // advance past the one we just yielded
      return {};
    }
    CurrentEntry = vfs::directory_entry();
    return {};
  }
};

// A read-only llvm::vfs::FileSystem serving the embedded tree at VROOT/<rel>.
// Paths outside VROOT return no_such_file so an OverlayFileSystem falls through.
class ZipVFS : public vfs::FileSystem {
  std::string CWD = "/";

  // Resolve a Twine path to a node index, or -1 if not a VROOT node. `norm`
  // (caller-owned) receives the normalized absolute path and `rel` points into
  // it, so the caller must keep `norm` alive while it uses `rel`. clang resolves
  // quoted/relative includes (e.g. musl crt1.c's "../../include/features.h")
  // into VROOT paths that still contain '..'/'.'; the real FS collapses those
  // implicitly, but our exact-match in-memory tree must do it explicitly.
  long lookup(const llvm::Twine &Path, llvm::SmallVectorImpl<char> &norm,
              StringRef &rel, bool &under) {
    Path.toVector(norm);
    llvm::sys::path::remove_dots(norm, /*remove_dot_dot=*/true);
    under = toRel(StringRef(norm.data(), norm.size()), rel);
    if (!under)
      return -1;
    return unpin_vfs_find(rel.data(), rel.size());
  }

public:
  llvm::ErrorOr<vfs::Status> status(const llvm::Twine &Path) override {
    StringRef rel;
    bool under;
    llvm::SmallString<256> norm;
    long idx = lookup(Path, norm, rel, under);
    if (!under || idx < 0)
      return llvm::errc::no_such_file_or_directory;
    const char *p = nullptr;
    size_t plen = 0;
    int isDir = 0;
    uint64_t size = 0;
    unpin_vfs_entry((size_t)idx, &p, &plen, &isDir, &size);
    llvm::SmallString<256> Storage;
    return statusFor((size_t)idx, Path.toStringRef(Storage), isDir != 0, size);
  }

  llvm::ErrorOr<std::unique_ptr<vfs::File>>
  openFileForRead(const llvm::Twine &Path) override {
    StringRef rel;
    bool under;
    llvm::SmallString<256> norm;
    long idx = lookup(Path, norm, rel, under);
    if (!under || idx < 0)
      return llvm::errc::no_such_file_or_directory;
    const char *p = nullptr;
    size_t plen = 0;
    int isDir = 0;
    uint64_t size = 0;
    unpin_vfs_entry((size_t)idx, &p, &plen, &isDir, &size);
    if (isDir)
      return llvm::errc::is_a_directory;
    llvm::SmallString<256> Storage;
    return std::unique_ptr<vfs::File>(
        new ZipFile((size_t)idx, Path.toStringRef(Storage), false, size));
  }

  vfs::directory_iterator dir_begin(const llvm::Twine &Dir,
                                    std::error_code &EC) override {
    StringRef rel;
    bool under;
    llvm::SmallString<256> norm;
    long idx = lookup(Dir, norm, rel, under);
    if (!under || idx < 0) {
      EC = llvm::errc::no_such_file_or_directory;
      return {};
    }
    return vfs::directory_iterator(std::make_shared<ZipDirIter>(rel, EC));
  }

  llvm::ErrorOr<std::string> getCurrentWorkingDirectory() const override {
    return CWD;
  }
  std::error_code setCurrentWorkingDirectory(const llvm::Twine &Path) override {
    CWD = Path.str();
    return {};
  }
};

llvm::IntrusiveRefCntPtr<vfs::FileSystem> buildOverlay() {
  llvm::IntrusiveRefCntPtr<vfs::FileSystem> real = vfs::getRealFileSystem();
  if (!unpin_vfs_available())
    return real; // un-packed dev build: behave like stock clang
  auto overlay = llvm::makeIntrusiveRefCnt<vfs::OverlayFileSystem>(real);
  overlay->pushOverlay(llvm::makeIntrusiveRefCnt<ZipVFS>());
  return overlay;
}

} // namespace

namespace unpin {

llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> overlayBaseFS() {
  static llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> fs = buildOverlay();
  return fs;
}

} // namespace unpin
