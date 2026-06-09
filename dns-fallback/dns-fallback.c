/*
 * unpin DNS fallback — __wrap_getaddrinfo / __wrap_freeaddrinfo
 * ============================================================
 *
 * Why this exists
 * ---------------
 * unpins ships fully static musl binaries. musl's resolver reads
 * /etc/resolv.conf and, when that file is absent or has no `nameserver`
 * line, falls back to a single nameserver: 127.0.0.1. On Android there is
 * no /etc/resolv.conf (the OS resolves names through Bionic + netd, which a
 * non-Bionic static binary can't reach), so every catalog binary that
 * resolves a hostname queries 127.0.0.1:53, gets nothing, and fails — the
 * symptom is "can't download, won't resolve the host".
 *
 * The fix, applied catalog-wide at the libc boundary
 * --------------------------------------------------
 * Every linux-static artifact is linked with `-Wl,--wrap=getaddrinfo`
 * `-Wl,--wrap=freeaddrinfo` plus this archive (see nix-lib's withDnsFallback).
 * `--wrap` reroutes ALL references to getaddrinfo — including those inside
 * statically-linked libcurl.a etc., and including Rust's std::net resolution,
 * which emits the same getaddrinfo symbol — to __wrap_getaddrinfo here. So a
 * single C object fixes the whole C catalog AND the Rust binaries (unpin, …)
 * with no per-binary change. The linker pulls this object only if the binary
 * actually references getaddrinfo, so DCE drops it from tree/jq/coreutils/…
 *
 * What it does, precisely
 * -----------------------
 * __wrap_getaddrinfo delegates to the real resolver in every normal case
 * (desktop Linux/macOS, IP literals, AI_NUMERICHOST). It only takes over when
 * BOTH hold:
 *   - there is no configured resolver — /etc/resolv.conf is absent, or present
 *     but with no `nameserver` line (exactly when musl would fall back to
 *     127.0.0.1): Android, or a barebones container; and
 *   - the node is a real hostname (not a numeric literal).
 * In that case it does its own DNS query over UDP/53 to a public resolver
 * (1.1.1.1, then 8.8.8.8). This never masks a configured resolver's NXDOMAIN
 * on a normal system, and it avoids the ~10 s 127.0.0.1 probe musl would
 * otherwise spend before failing (we skip __real_getaddrinfo entirely on the
 * fallback path).
 *
 * Memory contract with the wrapped freeaddrinfo
 * ---------------------------------------------
 * musl's freeaddrinfo assumes its addrinfo is embedded in musl's private
 * `struct aibuf` and frees the enclosing block — it would corrupt heap if
 * handed our own allocation. So freeaddrinfo is wrapped too: addrinfo chains
 * we allocate carry a magic word in the 8 bytes immediately preceding the
 * first addrinfo; __wrap_freeaddrinfo recognises ours by that word and frees
 * our block, delegating everything else to the real freeaddrinfo. Reading the
 * 8 bytes before a *foreign* addrinfo never faults: musl hands back
 * `&aibuf->ai` with addrinfo as the FIRST member of its aibuf, so those bytes
 * are the allocator's own chunk metadata — always mapped just below a live
 * heap block. They won't equal the magic, so we fall through to the real
 * freeaddrinfo. (Formally it is an 8-byte read just under the user allocation:
 * harmless on musl, though ASAN would flag it; a locked registry of our own
 * pointers would avoid it but isn't worth the cost for static-musl-only.)
 *
 * Known prototype simplifications (follow-ups)
 * --------------------------------------------
 *   - UDP only; no TCP fallback on a truncated (TC=1) response. Fine for the
 *     small A/AAAA sets of github.com & friends.
 *   - When hints->ai_socktype is 0 we emit SOCK_STREAM entries (what every
 *     unpins network tool connects with); the real getaddrinfo would also
 *     emit DGRAM/RAW variants.
 *   - Named services beyond a tiny built-in table resolve to port 0 (the real
 *     resolver would consult /etc/services). Numeric ports (the common case)
 *     are exact.
 *   - DoH (443) is the intended last-resort second fallback for networks that
 *     block UDP/53; it needs a TLS stack and is deliberately NOT here. See the
 *     design notes — it belongs only where a TLS stack already exists.
 */

#define _GNU_SOURCE
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>

extern int  __real_getaddrinfo(const char *, const char *,
                               const struct addrinfo *, struct addrinfo **);
extern void __real_freeaddrinfo(struct addrinfo *);

#define UNPIN_DNS_MAGIC 0x756E70696E444E53ULL /* "unpinDNS" */
#define MAXADDR         8
#define DNS_TIMEOUT_MS  3000

/* Public resolvers tried in order. Hardcoded on purpose: a binary with no
 * /etc/resolv.conf (Android, minimal containers) still resolves. */
static const char *const RESOLVERS[] = { "1.1.1.1", "8.8.8.8" };

/* One contiguous allocation per resolved name. `magic` MUST sit immediately
 * before `ai[]` (no padding: sockaddr_storage/uint64_t/addrinfo are all
 * 8-aligned), so __wrap_freeaddrinfo can detect ours by reading the 8 bytes
 * just before the returned addrinfo. */
struct fb {
    struct sockaddr_storage ss[MAXADDR];
    char                    canon[256];
    uint64_t                magic;
    struct addrinfo         ai[MAXADDR];
};

/* Mirror musl's own resolver-fallback trigger: /etc/resolv.conf absent, or
 * present but with no usable `nameserver` line. In both cases musl would query
 * 127.0.0.1 and fail, so that's precisely where we take over. A file WITH a
 * nameserver (even an unreachable one) means a resolver IS configured — we
 * delegate and never mask it. */
static int no_configured_resolver(void)
{
    int fd = open("/etc/resolv.conf", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 1;                       /* absent */
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) return 1;                       /* empty / unreadable */
    buf[n] = '\0';
    for (char *p = buf; *p; ) {
        char *s = p;
        while (*s == ' ' || *s == '\t') s++;
        if (strncmp(s, "nameserver", 10) == 0 &&
            (s[10] == ' ' || s[10] == '\t'))
            return 0;                           /* a resolver is configured */
        char *nl = strchr(p, '\n');
        if (!nl) break;
        p = nl + 1;
    }
    return 1;                                   /* no nameserver line */
}

/* Fallback only when there is no configured resolver and `node` is a hostname.
 * Numeric literals (v4/v6) and NULL go to the real resolver, which needs no
 * DNS for them. */
static int want_fallback(const char *node)
{
    struct in_addr  a4;
    struct in6_addr a6;
    if (!node || !*node)                       return 0;
    if (inet_pton(AF_INET,  node, &a4) == 1)   return 0;
    if (inet_pton(AF_INET6, node, &a6) == 1)   return 0;
    return no_configured_resolver();
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
     * resolver to map the service only (node = NULL → no DNS). This reuses
     * libc + /etc/services, so anything in /etc/services works (e.g. whois'
     * "nicname"). */
    {
        struct addrinfo h, *r = NULL;
        memset(&h, 0, sizeof h);
        h.ai_family   = AF_INET;
        h.ai_socktype = (hints && hints->ai_socktype) ? hints->ai_socktype : SOCK_STREAM;
        if (__real_getaddrinfo(NULL, service, &h, &r) == 0 && r) {
            int p = ntohs(((struct sockaddr_in *)r->ai_addr)->sin_port);
            __real_freeaddrinfo(r);
            if (p) return p;
        }
    }

    /* last resort — a tiny built-in table for the case where /etc/services is
     * also absent (some Android layouts). Covers the services unpins tools
     * actually use. */
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
    buf[0] = id >> 8; buf[1] = id & 0xff;
    buf[2] = 0x01;                      /* RD (recursion desired) */
    buf[5] = 0x01;                      /* QDCOUNT = 1 */
    int qn = encode_qname(host, buf + 12, cap - 16);
    if (qn < 0) return -1;
    size_t o = 12 + qn;
    buf[o++] = qtype >> 8; buf[o++] = qtype & 0xff;  /* QTYPE */
    buf[o++] = 0x00;       buf[o++] = 0x01;          /* QCLASS = IN */
    return (int)o;
}

/* Send `q` to `server`:53 over UDP, wait DNS_TIMEOUT_MS, read the reply into
 * `resp`. Returns reply length (>= 12) or -1. */
static int dns_exchange(const char *server, const unsigned char *q, int qlen,
                        unsigned char *resp, size_t rcap, uint16_t id)
{
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port   = htons(53);
    if (inet_pton(AF_INET, server, &sa.sin_addr) != 1) return -1;

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    int rc = -1;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0 &&
        send(fd, q, qlen, 0) == qlen) {
        struct pollfd pf = { .fd = fd, .events = POLLIN };
        if (poll(&pf, 1, DNS_TIMEOUT_MS) == 1 && (pf.revents & POLLIN)) {
            ssize_t n = recv(fd, resp, rcap, 0);
            /* Match the transaction ID. The socket is connect()ed on a fresh
             * ephemeral port per call, so off-path packets are already
             * filtered; this rejects a stray/duplicate datagram. */
            if (n >= 12 && resp[0] == (id >> 8) && resp[1] == (id & 0xff))
                rc = (int)n;
        }
    }
    close(fd);
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

/* Parse answers of type `qtype` (1=A, 28=AAAA) into b->ss/b->ai, appending
 * from *count. Returns 0 on success (possibly 0 records), -1 if malformed. */
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
                s->sin_port   = htons(port);
                memcpy(&s->sin_addr, p, 4);
                b->ai[idx].ai_family  = AF_INET;
                b->ai[idx].ai_addrlen = sizeof(struct sockaddr_in);
                (*count)++;
            } else if (qtype == 28 && rdlen == 16) {          /* AAAA */
                struct sockaddr_in6 *s = (struct sockaddr_in6 *)&b->ss[idx];
                memset(s, 0, sizeof *s);
                s->sin6_family = AF_INET6;
                s->sin6_port   = htons(port);
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

int __wrap_getaddrinfo(const char *node, const char *service,
                       const struct addrinfo *hints, struct addrinfo **res)
{
    int flags = hints ? hints->ai_flags : 0;

    if ((flags & AI_NUMERICHOST) || !want_fallback(node))
        return __real_getaddrinfo(node, service, hints, res);

    int family   = hints ? hints->ai_family   : AF_UNSPEC;
    int socktype = hints ? hints->ai_socktype : 0;
    int protocol = hints ? hints->ai_protocol : 0;
    int port     = parse_port(service, hints);

    struct fb *b = calloc(1, sizeof *b);
    if (!b) return EAI_MEMORY;
    b->magic = UNPIN_DNS_MAGIC;
    int count = 0;

    int qtypes[2], nq = 0;
    if      (family == AF_INET)  qtypes[nq++] = 1;
    else if (family == AF_INET6) qtypes[nq++] = 28;
    else { qtypes[nq++] = 1; qtypes[nq++] = 28; }

    unsigned char q[300], r[1500];
    uint16_t id = (uint16_t)(getpid() ^ (uintptr_t)b);

    for (int qi = 0; qi < nq && count < MAXADDR; qi++) {
        uint16_t qid = id++;
        int qlen = build_query(node, qtypes[qi], q, sizeof q, qid);
        if (qlen < 0) continue;
        for (size_t si = 0; si < sizeof RESOLVERS / sizeof *RESOLVERS; si++) {
            int rlen = dns_exchange(RESOLVERS[si], q, qlen, r, sizeof r, qid);
            if (rlen > 0) {
                parse_resp(r, rlen, qtypes[qi], port, b, &count);
                break;                       /* got an answer from this server */
            }
        }
    }

    if (count == 0) { free(b); return EAI_NONAME; }

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

void __wrap_freeaddrinfo(struct addrinfo *res)
{
    if (res) {
        uint64_t m;
        memcpy(&m, (const char *)res - sizeof(uint64_t), sizeof m);
        if (m == UNPIN_DNS_MAGIC) {
            free((char *)res - offsetof(struct fb, ai));
            return;
        }
    }
    __real_freeaddrinfo(res);
}
