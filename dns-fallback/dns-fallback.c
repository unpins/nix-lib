/*
 * unpin DNS fallback — getaddrinfo interposition with a UDP + DoH safety net
 * =========================================================================
 *
 * Why this exists
 * ---------------
 * An unpins program resolves names through the OS resolver (getaddrinfo). On a
 * normal desktop that always works. But a fully static musl binary on Android
 * has no /etc/resolv.conf — musl then falls back to 127.0.0.1:53, where nothing
 * listens, and every lookup fails ("can't download, won't resolve the host").
 * The same gap appears on any host whose configured resolver is dead/unreachable.
 *
 * What it does, precisely
 * -----------------------
 * It interposes getaddrinfo and always calls the real OS resolver FIRST — exactly
 * as if this code weren't here — taking over only when that call could not REACH
 * a resolver. The two failure outcomes are distinct:
 *   - unreachable resolver  -> EAI_AGAIN  (our trigger): a resolver-less host
 *     (Android, a barebones container) or a dead/unreachable nameserver;
 *   - "no such name"        -> EAI_NONAME (respected, NOT a trigger): an
 *     authoritative NXDOMAIN from a working resolver. Re-asking a public resolver
 *     would mask it and break split-horizon DNS, so we never do.
 * The fallback is OPT-IN: it stays dormant unless the user pointed it at a
 * resolver, so by default a reach failure surfaces unchanged (and unpin then
 * teaches the user how to turn it on). Two opt-in sources, checked in order:
 *   - $UNPIN_DNS — space-separated IPv4 literals, a one-shot override;
 *   - `dns = <ip> …` in unpin's config file — read by this shim itself (see
 *     config_dns), so EVERY unpins program honours it without an env var.
 * Only for a real hostname (numeric literals / AI_NUMERICHOST need no DNS), only
 * on a reach failure, and only when a resolver is configured does it run its own
 * query over UDP/53 to that resolver. With nothing configured it reports the
 * condition (unpin_dns_note_unreachable) and returns the real error untouched.
 * The rule is uniform on every platform: try the OS resolver, fall back only
 * when it can't reach one and the user opted in — so on a normal host the OS
 * answers and the fallback never runs.
 *
 * How it is interposed (per toolchain)
 * ------------------------------------
 * The same C, three link mechanisms, selected by #ifdef:
 *   - Linux (static musl) and Windows (mingw): GNU ld's `-Wl,--wrap=getaddrinfo`
 *     `-Wl,--wrap=freeaddrinfo` reroute every reference (the C catalog, libcurl,
 *     and Rust's std::net all emit the same symbol) to __wrap_getaddrinfo; the
 *     originals are reachable as __real_getaddrinfo. See nix-lib's withDnsFallback.
 *   - macOS: Apple's ld64 has no --wrap, so we DEFINE getaddrinfo/freeaddrinfo
 *     (the linker binds every in-binary reference to ours; the build force-loads
 *     this archive so the definition wins over libSystem's) and reach the real
 *     libSystem ones via dlsym(RTLD_NEXT, …).
 * The linker pulls this object only when getaddrinfo is referenced, so it is
 * dropped from non-resolving tools (tree/jq/coreutils/…).
 *
 * Second stage — DoH over HTTPS/443 (optional)
 * --------------------------------------------
 * Some resolver-less networks also block UDP/53 (captive portals, firewalls).
 * When no resolver answers over UDP, this escalates to DNS-over-HTTPS (RFC 8484)
 * against the SAME resolvers — but it carries no TLS itself. Instead it calls
 * unpin_readurl, a generic "fetch this URL" hook provided as a WEAK definition
 * here (returning -1 = no transport) that a consumer already linking a TLS stack
 * OVERRIDES with a strong definition from that stack: the Rust tools over their
 * rustls (minreq); a C tool over its libcurl/OpenSSL. The shim builds the full
 * DoH request (URL + wire body + content-type) and hands it over; the hook knows
 * nothing about DNS. A program with no strong override keeps the weak stub and
 * stays UDP-only. (A weak *definition* — not a weak undefined reference — links
 * clean on ELF, Mach-O and COFF alike, unlike weak-undef which each format
 * resolves to NULL differently.)
 *
 * Memory contract with the wrapped freeaddrinfo
 * ---------------------------------------------
 * The real freeaddrinfo would corrupt the heap if handed our own allocation, so
 * it is interposed too: addrinfo chains we allocate carry a magic word in the 8
 * bytes immediately preceding the first addrinfo; the wrapped freeaddrinfo frees
 * our block on a match and delegates everything else to the real one. Reading the
 * 8 bytes before a *foreign* addrinfo reads the allocator's own chunk metadata —
 * mapped just below a live heap block on every platform's allocator; it won't
 * equal the magic, so we fall through. (An 8-byte read just under the user
 * allocation: harmless in practice, though ASAN would flag it.)
 *
 * Known simplifications (follow-ups)
 * ----------------------------------
 *   - UDP/DoH only; no TCP fallback on a truncated (TC=1) response. Fine for the
 *     small A/AAAA sets of github.com & friends.
 *   - hints->ai_socktype == 0 emits SOCK_STREAM entries (what unpins tools use).
 *   - Named services beyond a tiny built-in table resolve to port 0; numeric
 *     ports (the common case) are exact.
 */

/* Feature-test macros must precede every system header. */
#if defined(__APPLE__)
#  define _DARWIN_C_SOURCE 1
#elif !defined(_WIN32)
#  define _GNU_SOURCE 1
#endif

#if defined(_WIN32)
#  define UNPIN_WINDOWS 1
#  ifndef _WIN32_WINNT
#    define _WIN32_WINNT 0x0600          /* WSAPoll + inet_pton need Vista+ */
#  endif
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN 1
#  endif
#elif defined(__APPLE__)
#  define UNPIN_MACOS 1
#else
#  define UNPIN_LINUX 1
#endif

#if defined(UNPIN_WINDOWS)
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  include <windows.h>
#else
#  include <netdb.h>
#  include <sys/socket.h>
#  include <netinet/in.h>
#  include <arpa/inet.h>
#  include <poll.h>
#  include <unistd.h>
#  if defined(UNPIN_MACOS)
#    include <dlfcn.h>
#  endif
#endif
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>

/* ---- portable socket layer ------------------------------------------------ */
#if defined(UNPIN_WINDOWS)
typedef SOCKET    unpin_sock;
typedef WSAPOLLFD unpin_pollfd;
#  define UNPIN_BADSOCK     INVALID_SOCKET
#  define unpin_closesocket closesocket
#  define unpin_poll        WSAPoll
#  define UNPIN_PID()       ((unsigned)GetCurrentProcessId())
#else
typedef int           unpin_sock;
typedef struct pollfd unpin_pollfd;
#  define UNPIN_BADSOCK     (-1)
#  define unpin_closesocket close
#  define unpin_poll        poll
#  define UNPIN_PID()       ((unsigned)getpid())
#endif

/* ---- real getaddrinfo/freeaddrinfo + interposed entry-point names --------- */
#if defined(UNPIN_MACOS)
/* ld64 has no --wrap: we DEFINE getaddrinfo/freeaddrinfo and reach the real
 * libSystem implementations through dlsym(RTLD_NEXT, …). */
static int real_getaddrinfo(const char *node, const char *service,
                            const struct addrinfo *hints, struct addrinfo **res)
{
    typedef int (*fn_t)(const char *, const char *,
                        const struct addrinfo *, struct addrinfo **);
    static fn_t fn;
    if (!fn) fn = (fn_t)dlsym(RTLD_NEXT, "getaddrinfo");
    return fn(node, service, hints, res);
}
static void real_freeaddrinfo(struct addrinfo *res)
{
    typedef void (*fn_t)(struct addrinfo *);
    static fn_t fn;
    if (!fn) fn = (fn_t)dlsym(RTLD_NEXT, "freeaddrinfo");
    fn(res);
}
#  define ENTRY_GETADDRINFO  getaddrinfo
#  define ENTRY_FREEADDRINFO freeaddrinfo
#else
extern int  __real_getaddrinfo(const char *, const char *,
                               const struct addrinfo *, struct addrinfo **);
extern void __real_freeaddrinfo(struct addrinfo *);
#  define real_getaddrinfo   __real_getaddrinfo
#  define real_freeaddrinfo  __real_freeaddrinfo
#  define ENTRY_GETADDRINFO  __wrap_getaddrinfo
#  define ENTRY_FREEADDRINFO __wrap_freeaddrinfo
#endif

/* ---- optional generic HTTP-fetch hook for the DoH second stage ------------ *
 * A WEAK DEFINITION (returns -1 = no DoH transport). A consumer that links a TLS
 * stack provides a STRONG definition that overrides this — the Rust tools over
 * their rustls (minreq); a C tool over its libcurl/OpenSSL. A weak *definition*
 * (not a weak undefined reference) links clean on ELF, Mach-O and COFF.
 *
 * Contract — a dumb URL fetch that knows nothing about DNS:
 *   - Fetch `url`. If `body != NULL && bodylen > 0`, POST it with header
 *     `Content-Type: content_type` (and the same `Accept`); otherwise GET.
 *   - Write the response body into `result` (capacity `resultcap`).
 *   - Return the response length (> 0) on HTTP 200, or <= 0 on any failure.
 * For DoH the shim passes url = "https://<resolver>/dns-query", the DNS wire
 * query as `body`, content_type = "application/dns-message". The resolver in the
 * URL is a v4 literal, so the fetch needs no prior name resolution and the cert
 * validates against the resolver's IP-SAN (1.1.1.1 / 8.8.8.8 both carry one). */
__attribute__((weak))
int unpin_readurl(const char *url,
                  const unsigned char *body, int bodylen,
                  const char *content_type,
                  unsigned char *result, int resultcap)
{
    (void)url; (void)body; (void)bodylen;
    (void)content_type; (void)result; (void)resultcap;
    return -1;
}

#define UNPIN_DNS_MAGIC 0x756E70696E444E53ULL /* "unpinDNS" */
#define MAXADDR         8
#define DNS_TIMEOUT_MS  3000
#define MAX_RESOLVERS   8

/* Optional hook: the shim calls this once when a lookup needs the fallback but
 * the user has NOT opted in (no $UNPIN_DNS, no config `dns`), so it had to
 * surface the real EAI_AGAIN. A WEAK no-op definition here; unpin overrides it
 * with a strong definition (see unpin/src/dns.rs) that records the condition so
 * it can teach the user about opt-in DNS. Other tools that link this archive
 * keep the no-op. Same weak-definition mechanism as unpin_readurl above (a weak
 * *definition* links clean on ELF, Mach-O and COFF alike). */
__attribute__((weak))
void unpin_dns_note_unreachable(void) { }

/* Trim ASCII whitespace from both ends of `s` in place; returns the first
 * non-space byte. Mirrors the `.trim()` in unpin/src/config.rs (ASCII subset is
 * enough — a `dns` value is IPv4 literals, never multibyte whitespace). */
static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\r' ||
           *s == '\n' || *s == '\f' || *s == '\v') s++;
    char *e = s + strlen(s);
    while (e > s) {
        char c = e[-1];
        if (c == ' ' || c == '\t' || c == '\r' ||
            c == '\n' || c == '\f' || c == '\v') e--;
        else break;
    }
    *e = '\0';
    return s;
}

/* Join `a` + `b` into `out` (capacity `cap`, NUL-terminated). Returns 1, or 0
 * if it wouldn't fit. */
static int path_join(char *out, size_t cap, const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b);
    if (la + lb + 1 > cap) return 0;
    memcpy(out, a, la);
    memcpy(out + la, b, lb + 1);                /* copy b including its NUL */
    return 1;
}

/* Resolve unpin's config-file path into `out`. Mirrors unpin/src/platform.rs:
 *   - POSIX: $XDG_CONFIG_HOME/unpin/config, else $HOME/.config/unpin/config;
 *   - Windows: %APPDATA%\unpin\config.
 * Returns 1 on success, 0 when the base env var is unset/empty (no config). */
static int config_path(char *out, size_t cap)
{
#if defined(UNPIN_WINDOWS)
    const char *base = getenv("APPDATA");
    if (base && *base) return path_join(out, cap, base, "\\unpin\\config");
    return 0;
#else
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg) return path_join(out, cap, xdg, "/unpin/config");
    const char *home = getenv("HOME");
    if (home && *home) return path_join(out, cap, home, "/.config/unpin/config");
    return 0;
#endif
}

/* Read the `dns` value from unpin's config file into `out` (capacity `cap`).
 * Mirrors the flat grammar of unpin/src/config.rs: strip an inline `#` comment,
 * trim, split on the first `=`, last-wins. Read lazily on the error path only
 * (a lookup already failed), so the common case never touches the disk. Returns
 * 1 and writes the value on success, else 0. This is the opt-in that lets EVERY
 * unpins program (curl, git, …) honour the config — not just unpin — since the
 * shim can't ask unpin and must read the file itself. */
static int config_dns(char *out, size_t cap)
{
    char path[1024];
    if (!config_path(path, sizeof path)) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char line[512];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = '\0';                 /* inline comment to EOL */
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        if (strcmp(trim(line), "dns") != 0) continue;
        char *val = trim(eq + 1);
        size_t vl = strlen(val);
        if (vl && vl < cap) {                   /* last-wins: keep the final one */
            memcpy(out, val, vl + 1);
            found = 1;
        }
    }
    fclose(f);
    return found;
}

/* Tokenise a space/tab-separated list of IPv4 literals from `src` into `out[]`,
 * using caller-owned `buf` (which backs the returned pointers) as scratch.
 *
 * Entries MUST be IPv4 literals — used verbatim both as the UDP/53 peer and, for
 * DoH, as the host in https://<ip>/dns-query (cert checked against that IP's
 * SAN). A hostname can't be allowed: the DoH leg would try to resolve it and
 * recurse straight back through this interposer. Non-literal / IPv6 / overflow
 * tokens are skipped. Returns the count. */
static size_t tokenize_resolvers(const char *src, const char **out,
                                 char *buf, size_t bufcap)
{
    size_t n = 0, len = strlen(src);
    if (len >= bufcap) return 0;
    memcpy(buf, src, len + 1);
    char *p = buf;
    while (n < MAX_RESOLVERS) {
        while (*p == ' ' || *p == '\t') p++;            /* skip separators */
        if (!*p) break;
        char *tok = p;
        while (*p && *p != ' ' && *p != '\t') p++;
        if (*p) *p++ = '\0';                            /* terminate token */
        struct in_addr a4;
        if (inet_pton(AF_INET, tok, &a4) == 1)
            out[n++] = tok;            /* IPv4 literal — safe for UDP + DoH URL */
    }
    return n;
}

/* The resolver list for this call, OPT-IN only: $UNPIN_DNS (a one-shot
 * override) when it yields ≥ 1 valid literal, else the config `dns` key, else
 * empty. There is deliberately NO built-in default — the fallback never fires
 * without the user's explicit say-so; an empty return tells the caller to
 * surface the real EAI_AGAIN (and call unpin_dns_note_unreachable). `buf`
 * (caller-owned, alive for the whole resolution) backs the returned pointers. */
static size_t resolver_list(const char **out, char *buf, size_t bufcap)
{
    const char *env = getenv("UNPIN_DNS");
    if (env && *env) {
        size_t n = tokenize_resolvers(env, out, buf, bufcap);
        if (n) return n;                 /* env set and valid → use it */
    }
    char cfg[256];
    if (config_dns(cfg, sizeof cfg))
        return tokenize_resolvers(cfg, out, buf, bufcap);
    return 0;
}

/* One contiguous allocation per resolved name. `magic` MUST sit immediately
 * before `ai[]` (no padding: sockaddr_storage/uint64_t/addrinfo are all
 * 8-aligned), so the wrapped freeaddrinfo can detect ours by reading the 8 bytes
 * just before the returned addrinfo. */
struct fb {
    struct sockaddr_storage ss[MAXADDR];
    char                    canon[256];
    uint64_t                magic;
    struct addrinfo         ai[MAXADDR];
};

/* Our DNS fallback can only help a real hostname. Numeric literals (v4/v6) and
 * NULL need no DNS — the real resolver already handled or rejected them. */
static int want_fallback(const char *node)
{
    struct in_addr  a4;
    struct in6_addr a6;
    if (!node || !*node)                       return 0;
    if (inet_pton(AF_INET,  node, &a4) == 1)   return 0;
    if (inet_pton(AF_INET6, node, &a6) == 1)   return 0;
    return 1;                                   /* a real hostname */
}

static int parse_port(const char *service, const struct addrinfo *hints)
{
    if (!service || !*service) return 0;

    /* numeric — the common case (curl/minreq pass "443", "80", …) */
    int num = 1;
    for (const char *p = service; *p; p++)
        if (*p < '0' || *p > '9') { num = 0; break; }
    if (num) { long v = atol(service); return (v >= 0 && v <= 65535) ? (int)v : 0; }

    /* named — resolve it exactly as getaddrinfo would, by asking the real
     * resolver to map the service only (node = NULL → no DNS). Reuses the OS
     * services database, so anything there works (e.g. whois' "nicname"). */
    {
        struct addrinfo h, *r = NULL;
        memset(&h, 0, sizeof h);
        h.ai_family   = AF_INET;
        h.ai_socktype = (hints && hints->ai_socktype) ? hints->ai_socktype : SOCK_STREAM;
        if (real_getaddrinfo(NULL, service, &h, &r) == 0 && r) {
            int p = ntohs(((struct sockaddr_in *)r->ai_addr)->sin_port);
            real_freeaddrinfo(r);
            if (p) return p;
        }
    }

    /* last resort — a tiny built-in table for when the services database is also
     * absent (some Android layouts). Covers the services unpins tools use. */
    static const struct { const char *n; int p; } svc[] = {
        { "http", 80 }, { "https", 443 }, { "domain", 53 }, { "ftp", 21 },
        { "ssh", 22 }, { "ntp", 123 }, { "whois", 43 }, { "nicname", 43 }, { 0, 0 }
    };
    for (int i = 0; svc[i].n; i++)
        if (!strcmp(service, svc[i].n)) return svc[i].p;
    return 0;
}

/* "example.com" -> \7example\3com\0 . Returns encoded length, or -1. */
static int encode_qname(const char *host, unsigned char *out, size_t cap)
{
    size_t o = 0;
    for (const char *p = host; *p; ) {
        const char *dot = strchr(p, '.');
        size_t len = dot ? (size_t)(dot - p) : strlen(p);
        if (len == 0 || len > 63)        return -1;
        if (o + 1 + len + 1 > cap)       return -1;
        out[o++] = (unsigned char)len;
        memcpy(out + o, p, len); o += len;
        if (!dot) break;
        p = dot + 1;
    }
    out[o++] = 0;
    return (int)o;
}

static int build_query(const char *host, int qtype,
                       unsigned char *buf, size_t cap, uint16_t id)
{
    if (cap < 16) return -1;
    memset(buf, 0, 12);
    buf[0] = (unsigned char)(id >> 8); buf[1] = (unsigned char)(id & 0xff);
    buf[2] = 0x01;                      /* RD (recursion desired) */
    buf[5] = 0x01;                      /* QDCOUNT = 1 */
    int qn = encode_qname(host, buf + 12, cap - 16);
    if (qn < 0) return -1;
    size_t o = 12 + (size_t)qn;
    buf[o++] = (unsigned char)(qtype >> 8); buf[o++] = (unsigned char)(qtype & 0xff);
    buf[o++] = 0x00;                        buf[o++] = 0x01;          /* QCLASS = IN */
    return (int)o;
}

/* Send `q` to `server`:53 over UDP, wait DNS_TIMEOUT_MS, read the reply into
 * `resp`. Returns reply length (>= 12) or -1. */
static int dns_exchange(const char *server, const unsigned char *q, int qlen,
                        unsigned char *resp, size_t rcap, uint16_t id)
{
#if defined(UNPIN_WINDOWS)
    { WSADATA w; WSAStartup(MAKEWORD(2, 2), &w); }   /* refcounted; idempotent */
#endif
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port   = htons(53);
    if (inet_pton(AF_INET, server, &sa.sin_addr) != 1) return -1;

    unpin_sock fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd == UNPIN_BADSOCK) return -1;

    int rc = -1;
    if (connect(fd, (struct sockaddr *)&sa, (int)sizeof sa) == 0 &&
        send(fd, (const char *)q, qlen, 0) == qlen) {
        unpin_pollfd pf;
        memset(&pf, 0, sizeof pf);
        pf.fd = fd; pf.events = POLLIN;
        if (unpin_poll(&pf, 1, DNS_TIMEOUT_MS) == 1 && (pf.revents & POLLIN)) {
            /* The socket is connect()ed on a fresh ephemeral port per call, so
             * off-path packets are already filtered; the id check rejects a
             * stray/duplicate datagram. */
            int n = (int)recv(fd, (char *)resp, (int)rcap, 0);
            if (n >= 12 && resp[0] == (id >> 8) && resp[1] == (id & 0xff))
                rc = n;
        }
    }
    unpin_closesocket(fd);
    return rc;
}

/* Skip a (possibly compressed) DNS name. Returns the byte after it, or NULL. */
static const unsigned char *skip_name(const unsigned char *p,
                                      const unsigned char *end)
{
    while (p < end) {
        unsigned c = *p;
        if (c == 0)              return p + 1;
        if ((c & 0xC0) == 0xC0)  return (p + 2 <= end) ? p + 2 : NULL;
        p += c + 1;
    }
    return NULL;
}

/* Parse answers of type `qtype` (1=A, 28=AAAA) into b->ss/b->ai, appending from
 * *count. Returns 0 on success (possibly 0 records), -1 if malformed. */
static int parse_resp(const unsigned char *r, int rlen, int qtype, int port,
                      struct fb *b, int *count)
{
    if (rlen < 12)              return -1;
    if ((r[3] & 0x0f) != 0)     return 0;       /* rcode != NOERROR */
    int qd = (r[4] << 8) | r[5];
    int an = (r[6] << 8) | r[7];
    const unsigned char *p = r + 12, *end = r + rlen;

    for (int i = 0; i < qd; i++) {              /* skip the question section */
        p = skip_name(p, end);
        if (!p || p + 4 > end) return -1;
        p += 4;
    }
    for (int i = 0; i < an && *count < MAXADDR; i++) {
        p = skip_name(p, end);
        if (!p || p + 10 > end) return -1;
        int type  = (p[0] << 8) | p[1];
        int rdlen = (p[8] << 8) | p[9];
        p += 10;
        if (p + rdlen > end)    return -1;

        if (type == qtype) {
            int idx = *count;
            if (qtype == 1 && rdlen == 4) {                   /* A */
                struct sockaddr_in *s = (struct sockaddr_in *)&b->ss[idx];
                memset(s, 0, sizeof *s);
                s->sin_family = AF_INET;
                s->sin_port   = htons((uint16_t)port);
                memcpy(&s->sin_addr, p, 4);
                b->ai[idx].ai_family  = AF_INET;
                b->ai[idx].ai_addrlen = sizeof(struct sockaddr_in);
                (*count)++;
            } else if (qtype == 28 && rdlen == 16) {          /* AAAA */
                struct sockaddr_in6 *s = (struct sockaddr_in6 *)&b->ss[idx];
                memset(s, 0, sizeof *s);
                s->sin6_family = AF_INET6;
                s->sin6_port   = htons((uint16_t)port);
                memcpy(&s->sin6_addr, p, 16);
                b->ai[idx].ai_family  = AF_INET6;
                b->ai[idx].ai_addrlen = sizeof(struct sockaddr_in6);
                (*count)++;
            }
        }
        p += rdlen;
    }
    return 0;
}

int ENTRY_GETADDRINFO(const char *node, const char *service,
                      const struct addrinfo *hints, struct addrinfo **res)
{
    /* Always try the system resolver first — identical path on every platform. */
    int rc = real_getaddrinfo(node, service, hints, res);

    /* Take over only when it could not REACH a resolver (EAI_AGAIN and the other
     * transport/system failures). A success is returned as-is; EAI_NONAME is an
     * authoritative NXDOMAIN we must not mask; numeric literals / AI_NUMERICHOST
     * need no DNS. */
    int flags = hints ? hints->ai_flags : 0;
    if (rc == 0 || rc == EAI_NONAME ||
        (flags & AI_NUMERICHOST) || !want_fallback(node))
        return rc;

    /* …and only when the user OPTED IN (env $UNPIN_DNS or config `dns`). With no
     * resolver configured we can't help: latch the condition so unpin can teach
     * the user, and surface the real error unchanged. `dnsbuf` backs the parsed
     * strings and must outlive the loop below. */
    const char *resolvers[MAX_RESOLVERS];
    char dnsbuf[256];
    const size_t nres = resolver_list(resolvers, dnsbuf, sizeof dnsbuf);
    if (nres == 0) {
        unpin_dns_note_unreachable();
        return rc;
    }

    int family   = hints ? hints->ai_family   : AF_UNSPEC;
    int socktype = hints ? hints->ai_socktype : 0;
    int protocol = hints ? hints->ai_protocol : 0;
    int port     = parse_port(service, hints);

    struct fb *b = calloc(1, sizeof *b);
    if (!b) return rc;                 /* keep the real resolver's error */
    b->magic = UNPIN_DNS_MAGIC;
    int count = 0;

    int qtypes[2], nq = 0;
    if      (family == AF_INET)  qtypes[nq++] = 1;
    else if (family == AF_INET6) qtypes[nq++] = 28;
    else { qtypes[nq++] = 1; qtypes[nq++] = 28; }

    /* r is sized for a DoH reply (HTTPS has no 512-byte UDP limit); UDP recvs
     * into the same buffer and never fills it (we set no EDNS, so servers cap
     * UDP answers at 512). */
    unsigned char q[300], r[4096];
    uint16_t id = (uint16_t)(UNPIN_PID() ^ (uintptr_t)b);
    int udp_dead = 0;                  /* set once UDP/53 is blocked */
    int doh_dead = 0;                  /* set once DoH/443 is blocked */

    for (int qi = 0; qi < nq && count < MAXADDR; qi++) {
        uint16_t qid = id++;
        int qlen = build_query(node, qtypes[qi], q, sizeof q, qid);
        if (qlen < 0) continue;

        int answered = 0;                  /* got a DNS response (any rcode) */
        if (!udp_dead) {
            for (size_t si = 0; si < nres; si++) {
                int rlen = dns_exchange(resolvers[si], q, qlen, r, sizeof r, qid);
                if (rlen > 0) {
                    parse_resp(r, rlen, qtypes[qi], port, b, &count);
                    answered = 1;
                    break;                 /* this resolver answered over UDP */
                }
            }
            /* No resolver answered over UDP — treat port 53 as blocked for the
             * rest of this call, so the next qtype goes straight to DoH instead
             * of eating another full round of UDP timeouts. */
            if (!answered) udp_dead = 1;
        }

        /* Second stage: UDP got nothing → DoH/443. unpin_readurl is the weak stub
         * (returns -1) unless a TLS-carrying consumer overrode it; the doh_dead
         * short-circuit below then skips the rest cheaply. */
        if (!answered && !doh_dead) {
            int reached = 0;               /* a resolver answered over DoH */
            for (size_t si = 0; si < nres; si++) {
                /* "https://<ip>/dns-query" without snprintf — mingw routes
                 * snprintf through wide-char CRT code, dragging in extra deps;
                 * memcpy keeps the archive's libc footprint to the basics. */
                char url[64];
                static const char pfx[] = "https://", sfx[] = "/dns-query";
                size_t ip = strlen(resolvers[si]);
                if (sizeof pfx - 1 + ip + sizeof sfx > sizeof url) continue;
                size_t o = sizeof pfx - 1;
                memcpy(url, pfx, o);
                memcpy(url + o, resolvers[si], ip); o += ip;
                memcpy(url + o, sfx, sizeof sfx);   /* includes the NUL */
                int rlen = unpin_readurl(url, q, qlen, "application/dns-message",
                                         r, (int)sizeof r);
                if (rlen > 0) {
                    parse_resp(r, rlen, qtypes[qi], port, b, &count);
                    reached = 1;
                    break;                 /* this resolver answered over DoH */
                }
            }
            /* No resolver answered over DoH either — 443 is blocked or no TLS
             * provider is linked. Skip the DoH round for the next qtype rather
             * than re-paying the per-resolver timeout (mirrors udp_dead above). */
            if (!reached) doh_dead = 1;
        }
    }

    if (count == 0) { free(b); return rc; }   /* fallback empty → real's error */

    for (int i = 0; i < count; i++) {
        b->ai[i].ai_flags     = 0;
        b->ai[i].ai_socktype  = socktype ? socktype : SOCK_STREAM;
        b->ai[i].ai_protocol  = protocol;
        b->ai[i].ai_addr      = (struct sockaddr *)&b->ss[i];
        b->ai[i].ai_canonname = NULL;
        b->ai[i].ai_next      = (i + 1 < count) ? &b->ai[i + 1] : NULL;
    }
    if (flags & AI_CANONNAME) {
        strncpy(b->canon, node, sizeof b->canon - 1);
        b->ai[0].ai_canonname = b->canon;
    }
    *res = &b->ai[0];
    return 0;
}

void ENTRY_FREEADDRINFO(struct addrinfo *res)
{
    if (res) {
        uint64_t m;
        memcpy(&m, (const char *)res - sizeof(uint64_t), sizeof m);
        if (m == UNPIN_DNS_MAGIC) {
            free((char *)res - offsetof(struct fb, ai));
            return;
        }
    }
    real_freeaddrinfo(res);
}
