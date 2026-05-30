#!/usr/bin/env python3
"""Populate a staging `unpin/man/` tree from a share/man root, for packing into
the embedded-metadata ZIP (see docs/embedded-metadata.md).

Stdlib-only and free of the `zlib`/`gzip` modules so it runs under
`python3Minimal` in the nix build: `.gz` man pages are inflated via the `gzip`
CLI (always in the build PATH). The caller packs the produced tree with the
`zip` CLI (deflate + symlink entries) — this script never compresses.

Layout produced under <staging>/unpin/man/:
  - roff page  -> a regular file  <name>.<section>   (verbatim roff bytes)
  - `.so` stub -> a symlink       <name>.<section> -> <tgt_name>.<tgt_section>

Exit 3 when there are no man pages (a legit skip, mirrors the old mkman.py)."""
import sys, os, glob, subprocess, re


def read_man(path):
    with open(path, "rb") as f:
        raw = f.read()
    if path.endswith(".gz"):
        return subprocess.run(
            ["gzip", "-dc"], input=raw, stdout=subprocess.PIPE, check=True
        ).stdout
    return raw


def parse_name_section(fname):
    """('ls.1') -> ('ls', '1'); ('Foo.3pm.gz') -> ('Foo', '3pm')."""
    base = fname[:-3] if fname.endswith(".gz") else fname
    stem, dot, sec = base.rpartition(".")
    if not dot:
        return base, "1"
    return stem, (sec if re.match(r"\d", sec) else "1")


def detect_so(body):
    """Return (tgt_name, tgt_section) if `body` is purely a `.so` redirect."""
    real = [
        ln
        for ln in body.decode("latin-1").splitlines()
        if ln.strip() and not ln.startswith('.\\"')
    ]
    so = [ln for ln in real if ln.strip().startswith(".so ")]
    if so and len(so) == len(real):
        tgt = so[0].split(None, 1)[1].strip()
        return parse_name_section(os.path.basename(tgt))
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: mkmeta.py <man_root> <staging_dir>")
    man_root, staging = sys.argv[1], sys.argv[2]
    out = os.path.join(staging, "unpin", "man")
    seen = set()
    count = 0
    for d in sorted(glob.glob(os.path.join(man_root, "share", "man", "man[0-9]*"))):
        if not os.path.isdir(d):
            continue
        for fp in sorted(glob.glob(os.path.join(d, "*"))):
            if not os.path.isfile(fp):
                continue
            name, section = parse_name_section(os.path.basename(fp))
            entry = f"{name}.{section}"
            if entry in seen:  # first wins (same page in two man dirs)
                continue
            body = read_man(fp)
            os.makedirs(out, exist_ok=True)
            dst = os.path.join(out, entry)
            so = detect_so(body)
            if so:
                # Symlink to the target's `<name>.<section>` basename — the
                # reader resolves it within the archive, there is no fs to
                # `.so` into.
                os.symlink(f"{so[0]}.{so[1]}", dst)
            else:
                with open(dst, "wb") as f:
                    f.write(body)
            seen.add(entry)
            count += 1
    if count == 0:
        print("mkmeta: no man pages found, nothing to embed", file=sys.stderr)
        sys.exit(3)
    print(f"mkmeta: {count} man page(s) -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
