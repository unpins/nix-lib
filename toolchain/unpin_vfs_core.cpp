//===-- unpin_vfs_core.cpp - shared zstd-in-ZIP reader (see .h) -----------===//
//
// Decompress-only reader for the catalog `unpin-vfs-pack` container: a standard
// .zip whose entries use zstd (method 93), appended to the executable with
// file-adjusted (absolute) offsets so the whole binary reads as one archive.
// We mmap the executable, scan for the End-Of-Central-Directory record, walk
// the central directory into a sorted node table, and decompress each entry's
// frame lazily via libzstd's stateless one-shot ZSTD_decompress (linked in by
// zig already). No miniz, no ZIP writer — only the ~120 lines of reader we need.
//
// It is C++ (not C) purely so it slots into zig's existing `-std=c++17
// -fno-exceptions -fno-rtti` source lists (build.zig + CMakeLists) unchanged;
// the public surface keeps C linkage (unpin_vfs_core.h) for the zig half's
// `extern` calls and the clang half's includes.
//
//===----------------------------------------------------------------------===//
#include "unpin_vfs_core.h"

#include <atomic>
#include <new>

#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// The only zstd entry points the reader needs (no-dict, one-shot decode).
// Forward-declared rather than via <zstd.h> so this TU builds with no extra
// include path — zig already links libzstd into the binary, so these resolve at
// link time. `ZSTD_decompress` is stateless, hence thread-safe.
extern "C" size_t ZSTD_decompress(void *dst, size_t dstCapacity,
                                  const void *src, size_t srcSize);
extern "C" unsigned ZSTD_isError(size_t code);

// ZIP signatures and method numbers.
#define SIG_EOCD 0x06054b50u // end of central directory
#define SIG_CEN 0x02014b50u  // central directory file header
#define SIG_LOC 0x04034b50u  // local file header
#define METHOD_STORE 0
#define METHOD_ZSTD 93

namespace {

struct Entry {
    char *path;          // malloc'd, NUL-terminated, no trailing slash
    size_t path_len;
    int is_dir;
    uint16_t method;
    uint64_t comp_off;   // absolute offset of compressed data in the image
    uint64_t comp_len;
    uint64_t uncomp_len;
    std::atomic<void *> data; // lazily inflated, NUL-terminated; null until read
};

const uint8_t *g_image;
size_t g_image_size;
Entry *g_entries;
size_t g_nentries;
int g_available;
pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
pthread_once_t g_once = PTHREAD_ONCE_INIT;
#ifdef UNPIN_VFS_TEST_MAIN
int g_test_mode; // set by test_init_path; suppresses /proc/self/exe
#endif

uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

// Scan backwards for the EOCD signature (within the last 64KiB+22; our packer
// writes an empty archive comment, but be tolerant).
const uint8_t *find_eocd(const uint8_t *img, size_t size) {
    if (size < 22)
        return nullptr;
    size_t maxback = size < (22u + 65535u) ? size : (22u + 65535u);
    for (size_t i = 22; i <= maxback; i++) {
        const uint8_t *p = img + size - i;
        if (rd32(p) == SIG_EOCD)
            return p;
    }
    return nullptr;
}

// Resolve a central-directory record's compressed-data offset by reading its
// local header (the local name/extra lengths can differ from the central
// ones). Returns the absolute data offset, or 0 on malformed input.
uint64_t data_offset(const uint8_t *img, size_t size, uint32_t lho) {
    if ((uint64_t)lho + 30 > size)
        return 0;
    const uint8_t *lh = img + lho;
    if (rd32(lh) != SIG_LOC)
        return 0;
    uint16_t name_len = rd16(lh + 26);
    uint16_t extra_len = rd16(lh + 28);
    uint64_t off = (uint64_t)lho + 30 + name_len + extra_len;
    return off <= size ? off : 0;
}

// qsort/bsearch comparator: bytewise lexicographic, shorter-is-less on a common
// prefix — identical ordering to zig's std.mem.order and the packer's sort.
int cmp_entry(const void *a, const void *b) {
    const Entry *x = (const Entry *)a, *y = (const Entry *)b;
    size_t n = x->path_len < y->path_len ? x->path_len : y->path_len;
    int c = memcmp(x->path, y->path, n);
    if (c)
        return c;
    return (x->path_len > y->path_len) - (x->path_len < y->path_len);
}

int parse(const uint8_t *img, size_t size) {
    const uint8_t *eocd = find_eocd(img, size);
    if (!eocd)
        return 0;
    uint16_t nrec = rd16(eocd + 10);
    uint32_t cd_size = rd32(eocd + 12);
    uint32_t cd_off = rd32(eocd + 16);
    if (nrec == 0xffff || cd_off == 0xffffffffu) // ZIP64 — packer forbids it
        return 0;
    if ((uint64_t)cd_off + cd_size > size)
        return 0;

    // +1 for the synthetic root node. Value-init so each std::atomic is zeroed.
    Entry *es = new (std::nothrow) Entry[(size_t)nrec + 1]();
    if (!es)
        return 0;
    size_t n = 0;

    // Synthetic root ("", dir) — the zig half asserts node[0] is the root.
    es[n].path = strdup("");
    es[n].path_len = 0;
    es[n].is_dir = 1;
    n++;

    const uint8_t *p = img + cd_off;
    const uint8_t *cd_end = p + cd_size;
    for (uint16_t i = 0; i < nrec; i++) {
        if (p + 46 > cd_end || rd32(p) != SIG_CEN)
            goto fail;
        {
            uint16_t method = rd16(p + 10);
            uint32_t comp = rd32(p + 20);
            uint32_t uncomp = rd32(p + 24);
            uint16_t name_len = rd16(p + 28);
            uint16_t extra_len = rd16(p + 30);
            uint16_t comment_len = rd16(p + 32);
            uint32_t lho = rd32(p + 42);
            const char *name = (const char *)(p + 46);
            if (p + 46 + name_len > cd_end)
                goto fail;

            // Lib-relative path: drop a single trailing '/' (dir marker).
            size_t plen = name_len;
            int is_dir = (plen > 0 && name[plen - 1] == '/');
            if (is_dir)
                plen--;

            // Skip any reserved ".unpin/..." metadata entry — the zig overlay
            // is packed without a shared dict (`--dict`) or alias list, so none
            // are expected, but never surface them as tree nodes if present.
            // (Dropping dict support is what lets the reader use the stateless
            // one-shot ZSTD_decompress with no dictionary plumbing.)
            if (!(plen >= 7 && memcmp(name, ".unpin/", 7) == 0)) {
                es[n].path = (char *)malloc(plen + 1);
                if (!es[n].path)
                    goto fail;
                memcpy(es[n].path, name, plen);
                es[n].path[plen] = '\0';
                es[n].path_len = plen;
                es[n].is_dir = is_dir;
                es[n].method = method;
                es[n].uncomp_len = uncomp;
                es[n].comp_len = comp;
                es[n].comp_off = is_dir ? 0 : data_offset(img, size, lho);
                es[n].data.store(nullptr);
                n++;
            }
            p += 46 + name_len + extra_len + comment_len;
        }
    }

    qsort(es, n, sizeof(Entry), cmp_entry);
    g_entries = es;
    g_nentries = n;
    return 1;

fail:
    for (size_t k = 0; k < n; k++)
        free(es[k].path);
    delete[] es;
    return 0;
}

void do_init() {
#ifdef UNPIN_VFS_TEST_MAIN
    if (g_test_mode)
        return; // the harness already installed an image via test_init_path
#endif
    int fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return;
    struct stat st;
    if (fstat(fd, &st) != 0 || (uint64_t)st.st_size < 22) {
        close(fd);
        return;
    }
    size_t size = (size_t)st.st_size;
    void *m = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED)
        return;
    g_image = (const uint8_t *)m;
    g_image_size = size;
    if (parse(g_image, size))
        g_available = 1;
    else
        munmap(m, size);
}

} // namespace

extern "C" {

int unpin_vfs_available(void) {
    pthread_once(&g_once, do_init);
    return g_available;
}

size_t unpin_vfs_count(void) {
    return unpin_vfs_available() ? g_nentries : 0;
}

int unpin_vfs_entry(size_t i, const char **path, size_t *path_len, int *is_dir,
                    uint64_t *size) {
    if (!unpin_vfs_available() || i >= g_nentries)
        return -1;
    const Entry *e = &g_entries[i];
    if (path)
        *path = e->path;
    if (path_len)
        *path_len = e->path_len;
    if (is_dir)
        *is_dir = e->is_dir;
    if (size)
        *size = e->uncomp_len;
    return 0;
}

long unpin_vfs_find(const char *path, size_t path_len) {
    if (!unpin_vfs_available())
        return -1;
    size_t lo = 0, hi = g_nentries;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        const Entry *e = &g_entries[mid];
        size_t n = e->path_len < path_len ? e->path_len : path_len;
        int c = memcmp(e->path, path, n);
        if (c == 0)
            c = (e->path_len > path_len) - (e->path_len < path_len);
        if (c < 0)
            lo = mid + 1;
        else if (c > 0)
            hi = mid;
        else
            return (long)mid;
    }
    return -1;
}

const void *unpin_vfs_data(size_t i, uint64_t *len) {
    if (!unpin_vfs_available() || i >= g_nentries)
        return nullptr;
    Entry *e = &g_entries[i];
    if (e->is_dir)
        return nullptr;
    if (len)
        *len = e->uncomp_len;

    void *d = e->data.load();
    if (d)
        return d;

    pthread_mutex_lock(&g_lock);
    d = e->data.load();
    if (!d) {
        void *buf = malloc(e->uncomp_len + 1);
        if (buf) {
            size_t got;
            if (e->method == METHOD_STORE) {
                memcpy(buf, g_image + e->comp_off, e->comp_len);
                got = e->comp_len;
            } else { // METHOD_ZSTD — one-shot, no dict
                got = ZSTD_decompress(buf, e->uncomp_len, g_image + e->comp_off,
                                      e->comp_len);
                if (ZSTD_isError(got))
                    got = (size_t)-1; // force the mismatch path below
            }
            if (got != e->uncomp_len) {
                free(buf);
            } else {
                ((char *)buf)[e->uncomp_len] = '\0';
                e->data.store(buf);
                d = buf;
            }
        }
    } else {
        d = e->data.load();
    }
    pthread_mutex_unlock(&g_lock);
    return d;
}

} // extern "C"

// ---------------------------------------------------------------------------
// Standalone test harness (compile with -DUNPIN_VFS_TEST_MAIN). Reads an
// arbitrary packed image instead of /proc/self/exe so the parser/decoder can be
// validated outside the multi-minute zig build.
// ---------------------------------------------------------------------------
#ifdef UNPIN_VFS_TEST_MAIN
#include <stdio.h>

// Test-only re-init from a file path (bypasses the /proc/self/exe one-shot).
static int test_init_path(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return 0;
    }
    size_t size = (size_t)st.st_size;
    void *m = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED)
        return 0;
    g_image = (const uint8_t *)m;
    g_image_size = size;
    g_test_mode = 1;
    g_available = parse(g_image, size);
    return g_available;
}

// Decompress every file node and compare against REFROOT/<path> on disk.
static int verify_all(const char *refroot) {
    size_t files = 0, dirs = 0, ok = 0, empty = 0;
    uint64_t maxlen = 0;
    char ref[8192];
    for (size_t i = 0; i < g_nentries; i++) {
        const Entry *e = &g_entries[i];
        if (e->is_dir) {
            dirs++;
            continue;
        }
        files++;
        uint64_t len = 0;
        const void *data = unpin_vfs_data(i, &len);
        if (!data) {
            fprintf(stderr, "decode failed: %s\n", e->path);
            return 1;
        }
        if (len == 0)
            empty++;
        if (len > maxlen)
            maxlen = len;
        snprintf(ref, sizeof ref, "%s/%s", refroot, e->path);
        FILE *f = fopen(ref, "rb");
        if (!f) {
            fprintf(stderr, "ref open failed: %s\n", ref);
            return 1;
        }
        fseek(f, 0, SEEK_END);
        long rn = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *rb = (char *)malloc(rn ? rn : 1);
        if (fread(rb, 1, rn, f) != (size_t)rn) {
            fprintf(stderr, "ref short: %s\n", ref);
            return 1;
        }
        fclose(f);
        if ((uint64_t)rn != len || memcmp(rb, data, len) != 0) {
            fprintf(stderr, "MISMATCH %s (ref %ld vs vfs %llu)\n", e->path, rn,
                    (unsigned long long)len);
            return 1;
        }
        free(rb);
        ok++;
    }
    printf("verify-all: %zu files (%zu ok, %zu empty), %zu dirs, max %llu bytes "
           "— ALL BYTE-IDENTICAL\n",
           files, ok, empty, dirs, (unsigned long long)maxlen);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,
                "usage: %s PACKED_IMAGE LOOKUP_PATH [REFERENCE_FILE]\n"
                "       %s PACKED_IMAGE --verify-all REFROOT\n",
                argv[0], argv[0]);
        return 2;
    }
    if (!test_init_path(argv[1])) {
        fprintf(stderr, "no archive in %s\n", argv[1]);
        return 1;
    }
    if (strcmp(argv[2], "--verify-all") == 0 && argc >= 4)
        return verify_all(argv[3]);

    printf("nodes: %zu (root path_len=%zu is_dir=%d)\n", g_nentries,
           g_entries[0].path_len, g_entries[0].is_dir);

    long idx = unpin_vfs_find(argv[2], strlen(argv[2]));
    if (idx < 0) {
        fprintf(stderr, "NOT FOUND: %s\n", argv[2]);
        return 1;
    }
    uint64_t len = 0;
    const void *data = unpin_vfs_data((size_t)idx, &len);
    if (!data) {
        fprintf(stderr, "decode failed: %s\n", argv[2]);
        return 1;
    }
    printf("found %s at idx %ld, %llu bytes, NUL-term=%d\n", argv[2], idx,
           (unsigned long long)len, ((const char *)data)[len] == '\0');

    if (argc >= 4) {
        FILE *f = fopen(argv[3], "rb");
        if (!f) {
            perror("ref");
            return 1;
        }
        fseek(f, 0, SEEK_END);
        long rn = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *rb = (char *)malloc(rn ? rn : 1);
        if (fread(rb, 1, rn, f) != (size_t)rn) {
            fprintf(stderr, "ref read short\n");
            return 1;
        }
        fclose(f);
        if ((uint64_t)rn != len || memcmp(rb, data, len) != 0) {
            fprintf(stderr, "MISMATCH vs %s (ref %ld vs vfs %llu)\n", argv[3], rn,
                    (unsigned long long)len);
            return 1;
        }
        printf("BYTE-IDENTICAL to %s\n", argv[3]);
        free(rb);
    }
    return 0;
}
#endif // UNPIN_VFS_TEST_MAIN
