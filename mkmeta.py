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

Exit 3 when there are no man pages (a legit skip, mirrors the old mkman.py).
Exit 1 on the two shapes of the case-fold defect, one on each side of it: a
pair of pages that differ only in case (visible on a case-sensitive build
host), and a `.so` page that redirects to itself (all that is left of such a
pair once a case-folding host — macOS — has merged them)."""
import sys, os, glob, subprocess, re, hashlib


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
    # lowercased entry -> (entry, fingerprint), for the case-fold guard below.
    by_lower = {}
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
            so = detect_so(body)
            link = f"{so[0]}.{so[1]}" if so else None
            # A `.so` to itself is not a page, it is the residue of a merge: on
            # macOS the store volume FOLDS CASE, so a `Foo.1` page and a
            # `foo.1` stub beside it are ONE file, and whichever was written
            # last is all that survives. By the time we read the tree the loss
            # already happened upstream of us — this self-link is its only
            # trace, and without this check it ships as a dangling entry.
            if link == entry:
                sys.exit(
                    f"mkmeta: {entry} redirects to itself ({fp}). A page and a "
                    "`.so` stub for it that differ only in case were merged by "
                    "a case-folding filesystem, and the page is gone. Give the "
                    "stub a distinct name, or drop it and declare the name "
                    "covered by another page with `manPage`."
                )
            # The same defect from the other side, where the filesystem does
            # NOT fold: both files are still here, so name the unportable pair
            # before a macOS build quietly keeps one of them. Identical content
            # is harmless duplication (openssl ships 9 such pairs in man3, byte
            # for byte the same page) and is left alone.
            fprint = hashlib.sha256((link or "\0").encode() + body).digest()
            twin = by_lower.get(entry.lower())
            if twin is not None and twin[1] != fprint:
                sys.exit(
                    f"mkmeta: {entry} and {twin[0]} differ only in case, and "
                    "carry different content. A case-folding filesystem (macOS) "
                    f"merges them and keeps one, so {twin[0]} would be lost "
                    f"there ({fp}). Give one of them a distinct name, or drop it "
                    "and declare the name covered by another page with `manPage`."
                )
            os.makedirs(out, exist_ok=True)
            dst = os.path.join(out, entry)
            if link:
                # Symlink to the target's `<name>.<section>` basename — the
                # reader resolves it within the archive, there is no fs to
                # `.so` into.
                os.symlink(link, dst)
            else:
                with open(dst, "wb") as f:
                    f.write(body)
            seen.add(entry)
            by_lower.setdefault(entry.lower(), (entry, fprint))
            count += 1
    if count == 0:
        print("mkmeta: no man pages found, nothing to embed", file=sys.stderr)
        sys.exit(3)
    print(f"mkmeta: {count} man page(s) -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
