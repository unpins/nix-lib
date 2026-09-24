# Uppercase kernel UAPI headers

The eight Linux netfilter UAPI headers zig's `lib/libc` does not carry, vendored
from nixpkgs' `linuxHeaders` 6.18.7.

**Why they are missing upstream and why they live in a tree of their own.** Each
is the uppercase twin of a header zig does ship — `xt_MARK.h` next to
`xt_mark.h`, `ipt_TTL.h` next to `ipt_ttl.h` — and the pair cannot share a
directory on a case-insensitive filesystem. They are not aliases: each defines
its own struct and include guard (`struct xt_DSCP_info`, `struct ipt_TTL_info`),
so collapsing a pair loses real declarations. zig prunes them for that reason,
and the engine payload is staged in `$(mktemp -d)`, which on a macOS builder is
`/private/tmp` — case-insensitive (measured). Kept apart, each directory holds
at most one of a pair on any host, and the in-binary VFS that serves them at
compile time is case-sensitive regardless.

**Why vendored rather than taken from nixpkgs.** `linuxHeaders` cannot be
evaluated from a darwin package set at all, and this payload is built on darwin
too. The content is stable kernel UAPI.

Staged to `libc/include/any-linux-any-uc` by `../default.nix`; put on `-isystem`
after `any-linux-any` by `../unpin_musl.cpp`.

Re-sync when nixpkgs' `linuxHeaders` moves:

```bash
K=$(nix eval --raw nixpkgs#linuxHeaders)/include
for h in $(cd toolchain/uapi-uc && find . -name '*.h' | sed 's|^\./||'); do
  install -Dm644 "$K/$h" "toolchain/uapi-uc/$h"
done
```

Upstream license: GPL-2.0 WITH Linux-syscall-note, as marked in each file.
