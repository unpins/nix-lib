/*
 * unpins: embedded Mozilla roots as a fallback for the host trust store.
 *
 * Included by crypto/x509/by_file.c and crypto/x509/by_dir.c; reached only
 * through the default lookups (X509_FILETYPE_DEFAULT), i.e. when the caller
 * asked for "the system's CAs" without naming a file or a directory. The first
 * row that matches decides:
 *
 *   SSL_CERT_FILE set        upstream: that file (plus the directory below).
 *   SSL_CERT_DIR set         upstream: that directory; on Unix also the
 *                            compiled default file, on Windows nothing else.
 *   UNPIN_CA_FALLBACK=force  the embedded roots and nothing else.
 *   UNPIN_CA_FALLBACK=off    Unix: upstream, the compiled default file and
 *                            directory. Windows: the system ROOT store only.
 *   Unix (default)           the first host bundle that EXISTS decides; else
 *                            every host hashed directory with certificates;
 *                            only a host with neither gets the embedded roots.
 *                            A bundle that exists but is empty, unreadable or
 *                            corrupt fails as upstream does - it never widens
 *                            trust to the embedded roots.
 *   Windows (default)        embedded roots + the system ROOT store (server
 *                            auth), minus what Windows distrusts.
 *
 * On Windows OPENSSLDIR (C:\ssl) is never read for certificates, neither its
 * cert.pem nor its certs\ directory: any user can create it. Cosmopolitan on
 * Windows follows the Windows rows with no ROOT store (no CryptoAPI), for the
 * same reason: the Unix paths map onto the drive root.
 */
#include <string.h>
#ifdef __COSMOPOLITAN__
/* IsWindows() needs _COSMO_SOURCE before the first libc header; uname() is
 * portable and cosmo reports sysname "Windows" there. */
# include <sys/utsname.h>
#endif

#define UNPIN_CA_AUTO 0
#define UNPIN_CA_OFF 1
#define UNPIN_CA_FORCE 2

static ossl_inline int unpin_ca_mode(void)
{
    const char *m = ossl_safe_getenv("UNPIN_CA_FALLBACK");

    if (m != NULL && strcmp(m, "off") == 0)
        return UNPIN_CA_OFF;
    if (m != NULL && strcmp(m, "force") == 0)
        return UNPIN_CA_FORCE;
    return UNPIN_CA_AUTO;
}

/* Windows semantics: no OPENSSLDIR trust, and (native only) the ROOT store. */
static ossl_inline int unpin_ca_windows(void)
{
#if defined(_WIN32)
    return 1;
#elif defined(__COSMOPOLITAN__)
    struct utsname u;

    return uname(&u) == 0 && strcmp(u.sysname, "Windows") == 0;
#else
    return 0;
#endif
}

/* The default directory lookup (by_dir.c): NULL adds no directory. */
static ossl_inline const char *unpin_ca_default_dir(void)
{
    const char *dir = ossl_safe_getenv(X509_get_default_cert_dir_env());

    if (dir != NULL)
        return dir;
    if (unpin_ca_windows() || unpin_ca_mode() == UNPIN_CA_FORCE)
        return NULL;
    return X509_get_default_cert_dir();
}

#ifndef UNPIN_CA_DIR_ONLY

#include <errno.h>
#include "internal/o_dir.h"
#include "unpin_ca_der.h" /* generated: unpin_ca_der[], UNPIN_CA_COUNT, unpin_ca_version[] */
#if defined(_WIN32)
# include <windows.h>
# include <wincrypt.h>
/* wincrypt.h macros that clash with OpenSSL type names (see openssl/types.h) */
# undef X509_NAME
# undef X509_EXTENSIONS
# undef PKCS7_SIGNER_INFO
# undef OCSP_REQUEST
# undef OCSP_RESPONSE
#else
# include <sys/stat.h>
#endif

#if defined(_WIN32)

/* A certificate in the Disallowed store (by thumbprint) is never trusted. */
static int unpin_ca_win_disallowed(HCERTSTORE dis, PCCERT_CONTEXT c)
{
    BYTE sha1[20];
    DWORD size = sizeof(sha1);
    CRYPT_HASH_BLOB blob;
    PCCERT_CONTEXT f;

    if (dis == NULL
        || !CertGetCertificateContextProperty(c, CERT_SHA1_HASH_PROP_ID, sha1, &size))
        return 0;
    blob.cbData = size;
    blob.pbData = sha1;
    f = CertFindCertificateInStore(dis, X509_ASN_ENCODING, 0, CERT_FIND_SHA1_HASH,
        &blob, NULL);
    if (f == NULL)
        return 0;
    CertFreeCertificateContext(f);
    return 1;
}

static int unpin_ca_win_server_auth(PCCERT_CONTEXT c)
{
    DWORD size = 0, i;
    CERT_ENHKEY_USAGE *u;
    int ok = 0;

    /* Partial distrust - "not for certificates issued after <date>" - cannot
     * be expressed in an X509_STORE, so such a root is left out altogether,
     * as gen-roots.py does with Mozilla's distrust-after roots. */
    if (CertGetCertificateContextProperty(c, CERT_DISALLOWED_FILETIME_PROP_ID, NULL, &size)
        || CertGetCertificateContextProperty(c, CERT_NOT_BEFORE_FILETIME_PROP_ID, NULL, &size))
        return 0;
    /* No EKU extension or property at all: valid for every use. */
    size = 0;
    if (!CertGetEnhancedKeyUsage(c, 0, NULL, &size))
        return GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
    if ((u = OPENSSL_malloc(size)) == NULL)
        return 0;
    if (CertGetEnhancedKeyUsage(c, 0, u, &size)) {
        if (u->cUsageIdentifier == 0)
            ok = GetLastError() == (DWORD)CRYPT_E_NOT_FOUND;
        for (i = 0; i < u->cUsageIdentifier; i++)
            if (strcmp(u->rgpszUsageIdentifier[i], szOID_PKIX_KP_SERVER_AUTH) == 0)
                ok = 1;
    }
    OPENSSL_free(u);
    return ok;
}

static int unpin_ca_load_windows_root(X509_STORE *store, OSSL_LIB_CTX *libctx,
    const char *propq, HCERTSTORE dis)
{
    HCERTSTORE hs = CertOpenSystemStoreW(0, L"ROOT");
    PCCERT_CONTEXT c = NULL;
    int count = 0;

    if (hs == NULL)
        return 0;
    while ((c = CertEnumCertificatesInStore(hs, c)) != NULL) {
        const unsigned char *p = c->pbCertEncoded;
        X509 *x;

        if (!unpin_ca_win_server_auth(c) || unpin_ca_win_disallowed(dis, c)
            || (x = X509_new_ex(libctx, propq)) == NULL)
            continue;
        if (d2i_X509(&x, &p, (long)c->cbCertEncoded) != NULL
            && X509_STORE_add_cert(store, x))
            count++;
        X509_free(x);
    }
    CertCloseStore(hs, 0);
    return count;
}

#else

typedef void *HCERTSTORE;

#endif

static int unpin_ca_load_embedded(X509_STORE *store, OSSL_LIB_CTX *libctx,
    const char *propq, HCERTSTORE dis)
{
    const unsigned char *p = unpin_ca_der;
    const unsigned char *end = unpin_ca_der + sizeof(unpin_ca_der);
    int count = 0;

    while (p < end) {
        const unsigned char *der = p;
        X509 *x = X509_new_ex(libctx, propq);
        int skip = 0;

        if (x == NULL)
            break;
        if (d2i_X509(&x, &p, (long)(end - p)) == NULL) {
            X509_free(x);
            break;
        }
#if defined(_WIN32)
        if (dis != NULL) {
            PCCERT_CONTEXT c = CertCreateCertificateContext(X509_ASN_ENCODING,
                der, (DWORD)(p - der));

            skip = c != NULL && unpin_ca_win_disallowed(dis, c);
            if (c != NULL)
                CertFreeCertificateContext(c);
        }
#else
        (void)der;
        (void)dis;
#endif
        if (!skip && !X509_STORE_add_cert(store, x)) {
            X509_free(x);
            break;
        }
        X509_free(x);
        count++;
    }
    if (count != UNPIN_CA_COUNT) {
        ERR_raise_data(ERR_LIB_X509, X509_R_LOADING_DEFAULTS,
            "%s: loaded %d", unpin_ca_version, count);
        return 0;
    }
    return 1;
}

#if !defined(_WIN32)

static int unpin_ca_load_file(X509_LOOKUP *ctx, const char *file,
    OSSL_LIB_CTX *libctx, const char *propq)
{
    return file != NULL
        && X509_load_cert_crl_file_ex(ctx, file, X509_FILETYPE_PEM, libctx,
               propq)
        != 0;
}

static const char *const unpin_ca_files[] = {
    "/etc/ssl/certs/ca-certificates.crt", /* Debian, Ubuntu, Arch, Gentoo, NixOS */
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", /* Fedora, RHEL */
    "/etc/pki/tls/certs/ca-bundle.crt", /* older Fedora, RHEL */
    "/etc/ssl/ca-bundle.pem", /* openSUSE */
    "/var/lib/ca-certificates/ca-bundle.pem", /* openSUSE */
    "/etc/pki/tls/cacert.pem", /* OpenELEC */
    "/etc/ssl/cert.pem", /* Alpine, macOS */
    "/data/data/com.termux/files/usr/etc/tls/cert.pem", /* Termux */
};

static const char *const unpin_ca_dirs[] = {
    "/etc/ssl/certs", /* most distributions */
    "/etc/pki/ca-trust/extracted/pem/directory-hash", /* Fedora 44+ */
    "/system/etc/security/cacerts", /* Android */
};

/* A dangling symlink counts as absent; anything else that stat() refuses
 * (EACCES, ELOOP, ...) counts as present, so the load fails closed. The one
 * exception is another Android app's private data (/data/data/<app>): it is
 * EACCES by design from adb shell or any other app, so it means absent. */
static int unpin_ca_exists(const char *path)
{
    struct stat st;

    if (stat(path, &st) == 0)
        return 1;
    if (errno == EACCES && strncmp(path, "/data/data/", 11) == 0)
        return 0;
    return errno != ENOENT && errno != ENOTDIR;
}

static int unpin_ca_is_hash_name(const char *n)
{
    int i;

    for (i = 0; i < 8; i++)
        if (!((n[i] >= '0' && n[i] <= '9') || (n[i] >= 'a' && n[i] <= 'f')))
            return 0;
    if (n[8] != '.' || n[9] == '\0')
        return 0;
    for (i = 9; n[i] != '\0'; i++)
        if (n[i] < '0' || n[i] > '9')
            return 0;
    return 1;
}

static int unpin_ca_dir_has_certs(const char *dir)
{
    OPENSSL_DIR_CTX *d = NULL;
    const char *e;
    char path[4096];
    struct stat st;
    int found = 0;

    while (!found && (e = OPENSSL_DIR_read(&d, dir)) != NULL) {
        if (!unpin_ca_is_hash_name(e))
            continue;
        BIO_snprintf(path, sizeof(path), "%s/%s", dir, e);
        found = stat(path, &st) == 0 && S_ISREG(st.st_mode);
    }
    if (d != NULL)
        OPENSSL_DIR_end(&d);
    return found;
}

static int unpin_ca_load_host(X509_LOOKUP *ctx, OSSL_LIB_CTX *libctx,
    const char *propq)
{
    X509_STORE *store = X509_LOOKUP_get_store(ctx);
    const char *deffile = X509_get_default_cert_file();
    const char *defdir = X509_get_default_cert_dir();
    size_t i;
    int found = 0;

    for (i = 0; i <= OSSL_NELEM(unpin_ca_files); i++) {
        const char *f = i == 0 ? deffile : unpin_ca_files[i - 1];

        if (f == NULL || !unpin_ca_exists(f))
            continue;
        if (unpin_ca_load_file(ctx, f, libctx, propq))
            return 1;
        ERR_raise_data(ERR_LIB_X509, X509_R_LOADING_DEFAULTS, "%s", f);
        return 0;
    }
    /* No bundle: the host's hashed directories join the store's directory
     * lookup - the compiled default one too, since a caller that asked only
     * for the default file has no directory lookup of its own. A store has
     * one hash_dir lookup and it drops repeated directories, so a caller that
     * also adds the default directory shares these. */
    for (i = 0; i <= OSSL_NELEM(unpin_ca_dirs); i++) {
        const char *dir = i == 0 ? defdir : unpin_ca_dirs[i - 1];
        X509_LOOKUP *dl;

        if (dir == NULL || !unpin_ca_dir_has_certs(dir))
            continue;
        dl = X509_STORE_add_lookup(store, X509_LOOKUP_hash_dir());
        if (dl == NULL || !X509_LOOKUP_add_dir(dl, dir, X509_FILETYPE_PEM))
            return 0;
        found = 1;
    }
    if (found)
        return 1;
    return unpin_ca_load_embedded(store, libctx, propq, NULL);
}

#endif

/* The default file lookup (by_file.c), reached with SSL_CERT_FILE unset. */
static int unpin_ca_load_default(X509_LOOKUP *ctx, OSSL_LIB_CTX *libctx,
    const char *propq)
{
    X509_STORE *store = X509_LOOKUP_get_store(ctx);
    int mode = unpin_ca_mode();
    int ok = 0;

    if (unpin_ca_windows()) {
        HCERTSTORE dis = NULL;

        if (ossl_safe_getenv(X509_get_default_cert_dir_env()) != NULL)
            return 0;
#if defined(_WIN32)
        dis = CertOpenSystemStoreW(0, L"Disallowed");
        if (mode != UNPIN_CA_FORCE)
            ok = unpin_ca_load_windows_root(store, libctx, propq, dis) > 0;
#endif
        if (mode != UNPIN_CA_OFF)
            ok |= unpin_ca_load_embedded(store, libctx, propq, dis);
#if defined(_WIN32)
        if (dis != NULL)
            CertCloseStore(dis, 0);
#endif
        return ok;
    }
#if defined(_WIN32)
    return ok;
#else
    if (ossl_safe_getenv(X509_get_default_cert_dir_env()) != NULL
        || mode == UNPIN_CA_OFF)
        return unpin_ca_load_file(ctx, X509_get_default_cert_file(), libctx, propq);
    if (mode == UNPIN_CA_FORCE)
        return unpin_ca_load_embedded(store, libctx, propq, NULL);
    return unpin_ca_load_host(ctx, libctx, propq);
#endif
}

#endif /* UNPIN_CA_DIR_ONLY */
