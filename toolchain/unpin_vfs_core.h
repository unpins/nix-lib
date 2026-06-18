/*===-- unpin_vfs_core.h - shared zstd-in-ZIP reader for the embedded lib tree -===
 *
 * The single ZIP/zstd reader shared by BOTH halves of the unpins single-binary
 * VFS: the zig half (src/unpin_vfs.zig, via these extern-C symbols) and the
 * clang half (src/unpin_clang_vfs.cpp, an llvm::vfs::FileSystem wrapper). It
 * reads the catalog-standard zstd-in-zip overlay (ZIP method 93) that
 * `unpin-vfs-pack --base <binsize>` appends to the executable — the same
 * "file-adjusted / self-extracting-archive" container the rest of the catalog
 * uses (man pages, runtime trees). Entry data is zstd-compressed and
 * decompressed LAZILY on first read, then cached for the process lifetime, so a
 * `zig cc` that touches a few dozen of the ~20k entries never inflates the rest.
 *
 * Having ONE C reader (vs. a hand-rolled parser in each half) keeps the two
 * halves byte-for-byte consistent and removes any zig-std zip/zstd API risk:
 * zig calls these functions through `extern`.
 *
 * Thread-safety: init runs once (pthread_once). `unpin_vfs_data` is safe to call
 * concurrently — the lazy decompress is serialized under an internal mutex (the
 * underlying zstd DCtx is not thread-safe), and the cached pointer is published
 * atomically so the post-decompress fast path is lock-free.
 *===----------------------------------------------------------------------===*/
#ifndef UNPIN_VFS_CORE_H
#define UNPIN_VFS_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 if an embedded archive was found and parsed, 0 otherwise (un-packed dev
 * build → both halves fall back to stock behaviour). Idempotent; triggers the
 * one-time init. Every other entry point ensures init internally too. */
int unpin_vfs_available(void);

/* Number of nodes (files + directories), sorted ascending by path (bytewise).
 * Node 0 is always the root, whose path is the empty string "". */
size_t unpin_vfs_count(void);

/* Describe node `i`. `*path` is lib-relative, '/'-separated, NUL-terminated,
 * no leading or trailing slash ("" = root); it stays valid for the process
 * lifetime. Any of the out-params may be NULL. Returns 0 on success, -1 if `i`
 * is out of range. */
int unpin_vfs_entry(size_t i, const char **path, size_t *path_len, int *is_dir,
                    uint64_t *size);

/* Binary-search for an exact path (lib-relative, no leading/trailing slash).
 * Returns the node index, or -1 if absent. */
long unpin_vfs_find(const char *path, size_t path_len);

/* Ensure node `i`'s file contents are decompressed and return a pointer to
 * them; `*len` (may be NULL) receives the uncompressed length. The buffer has a
 * trailing NUL at [len] (clang's lexer requires a null-terminated buffer) and
 * stays valid for the process lifetime. Returns NULL for a directory, an
 * out-of-range index, or a decode error. */
const void *unpin_vfs_data(size_t i, uint64_t *len);

#ifdef __cplusplus
}
#endif

#endif /* UNPIN_VFS_CORE_H */
