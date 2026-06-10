/* unpin-vfs-pack -- build a VFS blob (a .zip whose entries use zstd, method 93)
 * from a directory tree. Build-time tool; not shipped in the final binary.
 *
 *   unpin-vfs-pack OUT.zip ROOTDIR [--dict DICT] [--level N]
 *
 * Every regular file under ROOTDIR is stored under its ROOTDIR-relative path,
 * compressed with zstd. With --dict, a trained zstd dictionary (from
 * `zstd --train`) is used for every entry AND copied into the blob as the
 * reserved STORED entry ".unpin/zdict", so the reader can self-load it -- the
 * one piece a vanilla zstd-zip tool won't understand. Without --dict the output
 * is plain, interoperable zstd-in-zip.
 *
 * The archive stays a structurally standard .zip: any tool lists it; only
 * zstd-aware tools decode the entries.
 */
#define _XOPEN_SOURCE 700  /* nftw + FTW_PHYS */
#ifndef MINIZ_USE_ZSTD
#define MINIZ_USE_ZSTD
#endif
#include "miniz.h"
#include "unpin_zstd.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ftw.h>

#define ZDICT_ENTRY ".unpin/zdict"

static mz_zip_archive g_zip;
static const char *g_root;
static size_t g_root_len;
static int g_level = 19;
static long g_files, g_bytes_in, g_bytes_out;

static void *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    void *buf = malloc((size_t)n ? (size_t)n : 1);
    if (buf && n && fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); buf = NULL; }
    fclose(f);
    if (buf) *len = (size_t)n;
    return buf;
}

/* Add one file's bytes as a zstd (method 93) entry under `name`. */
static int add_file(const char *name, const void *data, size_t len) {
    size_t bound = unpin_zstd_bound(len);
    void *comp = malloc(bound ? bound : 1);
    if (!comp) return -1;
    size_t clen = unpin_zstd_compress(comp, bound, data, len, g_level);
    if (clen == 0 && len != 0) { free(comp); return -1; }
    mz_uint32 crc = (mz_uint32)mz_crc32(MZ_CRC32_INIT, (const mz_uint8 *)data, len);
    mz_bool ok = mz_zip_writer_add_mem_ex_v2(
        &g_zip, name, comp, clen, NULL, 0,
        MZ_ZIP_FLAG_COMPRESSED_DATA | MZ_ZIP_FLAG_ZSTD_DATA,
        (mz_uint64)len, crc, NULL, NULL, 0, NULL, 0);
    free(comp);
    if (ok) { g_files++; g_bytes_in += (long)len; g_bytes_out += (long)clen; }
    return ok ? 0 : -1;
}

static int visit(const char *fpath, const struct stat *sb, int typeflag, struct FTW *ftw) {
    (void)sb; (void)ftw;
    const char *rel = fpath + g_root_len;
    while (*rel == '/') rel++;
    if (!*rel) return 0;  /* the root itself */
    if (typeflag == FTW_D) {
        /* directory entry (trailing slash, empty) -- lets readdir enumerate */
        char dir[4096];
        snprintf(dir, sizeof dir, "%s/", rel);
        mz_zip_writer_add_mem(&g_zip, dir, "", 0, MZ_NO_COMPRESSION);
        return 0;
    }
    if (typeflag != FTW_F) return 0;  /* skip symlinks/specials */
    size_t len = 0;
    void *data = slurp(fpath, &len);
    if (!data) { fprintf(stderr, "read failed: %s\n", fpath); return 1; }
    int rc = add_file(rel, data, len);
    free(data);
    if (rc) { fprintf(stderr, "add failed: %s\n", rel); return 1; }
    return 0;
}

int main(int argc, char **argv) {
    const char *out = NULL, *root = NULL, *dictpath = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dict") && i + 1 < argc) dictpath = argv[++i];
        else if (!strcmp(argv[i], "--level") && i + 1 < argc) g_level = atoi(argv[++i]);
        else if (!out) out = argv[i];
        else if (!root) root = argv[i];
        else { fprintf(stderr, "unexpected arg: %s\n", argv[i]); return 2; }
    }
    if (!out || !root) {
        fprintf(stderr, "usage: %s OUT.zip ROOTDIR [--dict DICT] [--level N]\n", argv[0]);
        return 2;
    }

    void *dict = NULL; size_t dict_len = 0;
    if (dictpath) {
        dict = slurp(dictpath, &dict_len);
        if (!dict) { fprintf(stderr, "cannot read dict %s\n", dictpath); return 2; }
        unpin_zstd_set_dict(dict, dict_len);
    }

    memset(&g_zip, 0, sizeof g_zip);
    if (!mz_zip_writer_init_file(&g_zip, out, 0)) {
        fprintf(stderr, "cannot create %s\n", out); return 2;
    }

    /* The dict must be readable WITHOUT the dict, so store it (method 0). */
    if (dict)
        mz_zip_writer_add_mem(&g_zip, ZDICT_ENTRY, dict, dict_len, MZ_NO_COMPRESSION);

    g_root = root;
    g_root_len = strlen(root);
    if (nftw(root, visit, 16, FTW_PHYS) != 0) {
        fprintf(stderr, "walk failed\n"); return 1;
    }

    if (!mz_zip_writer_finalize_archive(&g_zip)) {
        fprintf(stderr, "finalize failed\n"); return 1;
    }
    mz_zip_writer_end(&g_zip);
    free(dict);

    fprintf(stderr, "packed %ld files: %ld -> %ld bytes (%.1f%%)%s\n",
            g_files, g_bytes_in, g_bytes_out,
            g_bytes_in ? 100.0 * g_bytes_out / g_bytes_in : 0.0,
            dictpath ? " [shared dict]" : "");
    return 0;
}
