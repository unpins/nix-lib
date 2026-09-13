/*
 * unpins: embedded Mozilla roots as a fallback for the host trust store.
 *
 * Included by crypto/x509/by_file.c; reached only through the default
 * certificate file lookup (X509_FILETYPE_DEFAULT), i.e. when the caller asked
 * for "the system's CAs" without naming a file. Policy:
 *
 *   SSL_CERT_FILE set        upstream: that file and nothing else.
 *   UNPIN_CA_FALLBACK=off    upstream: the compiled default file only.
 *   UNPIN_CA_FALLBACK=force  the embedded roots only.
 *   Unix, SSL_CERT_DIR set   upstream: the compiled default file only.
 *   Unix (default)           the first host bundle that EXISTS decides; else a
 *                            host hashed directory with certificates decides;
 *                            only a host with neither gets the embedded roots.
 *                            A bundle that exists but is empty, unreadable or
 *                            corrupt fails as upstream does - it never widens
 *                            trust to the embedded roots.
 *   Windows (default)        embedded roots + the system ROOT store (server
 *                            auth). OPENSSLDIR (C:\ssl) is never probed: any
 *                            user can create it.
 *   Cosmopolitan on Windows  embedded roots only: no CryptoAPI, and the Unix
 *                            paths map onto the drive root any user can write.
 */
#include <string.h>
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
#ifdef __COSMOPOLITAN__
/* IsWindows() needs _COSMO_SOURCE before the first libc header; uname() is
 * portable and cosmo reports sysname "Windows" there. */
# include <sys/utsname.h>
#endif

#define UNPIN_CA_AUTO 0
#define UNPIN_CA_OFF 1
#define UNPIN_CA_FORCE 2

static int unpin_ca_mode(void)
{
    const char *m = ossl_safe_getenv("UNPIN_CA_FALLBACK");

    if (m != NULL && strcmp(m, "off") == 0)
        return UNPIN_CA_OFF;
    if (m != NULL && strcmp(m, "force") == 0)
        return UNPIN_CA_FORCE;
    return UNPIN_CA_AUTO;
}

static int unpin_ca_load_embedded(X509_STORE *store, OSSL_LIB_CTX *libctx,
    const char *propq)
{
    const unsigned char *p = unpin_ca_der;
    const unsigned char *end = unpin_ca_der + sizeof(unpin_ca_der);
    int count = 0;

    while (p < end) {
        X509 *x = X509_new_ex(libctx, propq);

        if (x == NULL)
            break;
        if (d2i_X509(&x, &p, (long)(end - p)) == NULL
            || !X509_STORE_add_cert(store, x)) {
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

static int unpin_ca_load_file(X509_LOOKUP *ctx, const char *file,
    OSSL_LIB_CTX *libctx, const char *propq)
{
    return file != NULL
        && X509_load_cert_crl_file_ex(ctx, file, X509_FILETYPE_PEM, libctx,
               propq)
        != 0;
}

#if defined(_WIN32)

static int unpin_ca_win_server_auth(PCCERT_CONTEXT c)
{
    DWORD size = 0, i;
    CERT_ENHKEY_USAGE *u;
    int ok = 0;

    /* No EKU extension or property at all: valid for every use. */
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
    const char *propq)
{
    HCERTSTORE hs = CertOpenSystemStoreW(0, L"ROOT");
    PCCERT_CONTEXT c = NULL;
    int count = 0;

    if (hs == NULL)
        return 0;
    while ((c = CertEnumCertificatesInStore(hs, c)) != NULL) {
        const unsigned char *p = c->pbCertEncoded;
        X509 *x;

        if (!unpin_ca_win_server_auth(c) || (x = X509_new_ex(libctx, propq)) == NULL)
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
 * (EACCES, ELOOP, ...) counts as present, so the load fails closed. */
static int unpin_ca_exists(const char *path)
{
    struct stat st;

    if (stat(path, &st) == 0)
        return 1;
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

#endif

static int unpin_ca_load_default(X509_LOOKUP *ctx, OSSL_LIB_CTX *libctx,
    const char *propq)
{
    X509_STORE *store = X509_LOOKUP_get_store(ctx);
    int mode = unpin_ca_mode();

    if (mode == UNPIN_CA_OFF)
        return unpin_ca_load_file(ctx, X509_get_default_cert_file(), libctx, propq);
    if (mode == UNPIN_CA_FORCE)
        return unpin_ca_load_embedded(store, libctx, propq);

#if defined(_WIN32)
    if (ossl_safe_getenv(X509_get_default_cert_dir_env()) != NULL)
        return 0;
    return (unpin_ca_load_windows_root(store, libctx, propq) > 0)
        | unpin_ca_load_embedded(store, libctx, propq);
#else
    {
        const char *deffile = X509_get_default_cert_file();
        const char *defdir = X509_get_default_cert_dir();
        size_t i;
        int found = 0;

        if (ossl_safe_getenv(X509_get_default_cert_dir_env()) != NULL)
            return unpin_ca_load_file(ctx, deffile, libctx, propq);
# ifdef __COSMOPOLITAN__
        {
            struct utsname u;

            if (uname(&u) == 0 && strcmp(u.sysname, "Windows") == 0)
                return unpin_ca_load_embedded(store, libctx, propq);
        }
# endif
        for (i = 0; i <= OSSL_NELEM(unpin_ca_files); i++) {
            const char *f = i == 0 ? deffile : unpin_ca_files[i - 1];

            if (f == NULL || !unpin_ca_exists(f))
                continue;
            if (unpin_ca_load_file(ctx, f, libctx, propq))
                return 1;
            ERR_raise_data(ERR_LIB_X509, X509_R_LOADING_DEFAULTS, "%s", f);
            return 0;
        }
        /* The compiled default directory is the caller's own hash_dir lookup
         * (when it asked for one); other host directories are added to it. */
        if (defdir != NULL && unpin_ca_dir_has_certs(defdir))
            found = 1;
        for (i = 0; i < OSSL_NELEM(unpin_ca_dirs); i++) {
            X509_LOOKUP *dl;

            if ((defdir != NULL && strcmp(unpin_ca_dirs[i], defdir) == 0)
                || !unpin_ca_dir_has_certs(unpin_ca_dirs[i]))
                continue;
            found = 1;
            dl = X509_STORE_add_lookup(store, X509_LOOKUP_hash_dir());
            if (dl != NULL)
                X509_LOOKUP_add_dir(dl, unpin_ca_dirs[i], X509_FILETYPE_PEM);
        }
        if (found)
            return 1;
        return unpin_ca_load_embedded(store, libctx, propq);
    }
#endif
}
