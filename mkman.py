#!/usr/bin/env python3
"""Build a .unpin_man container blob from a share/man tree (DRAFT spec v1).

Stdlib-only and free of the `zlib`/`gzip` modules so it runs under
`python3Minimal` in the nix build: .gz man pages are inflated via the `gzip`
CLI (always in the build PATH), compression uses the `zstd` CLI, and CRC-32 is
a small pure-Python table implementation (standard IEEE poly, matches
`zlib.crc32`)."""
import sys, os, glob, struct, subprocess, argparse, re

BEGIN = b'\xff\xff' + b'UNPIN_MAN_v1_b2c9d1' + b'\xff\xff'
END   = b'\xff\xff' + b'UNPIN_MAN_ENDb2c9d1' + b'\xff\xff'
assert len(BEGIN) == len(END)

KIND_SO, KIND_ROFF = 0, 1

_CRC = []
for _n in range(256):
    _c = _n
    for _ in range(8):
        _c = (_c >> 1) ^ (0xEDB88320 & -(_c & 1))
    _CRC.append(_c)
def crc32(data):
    c = 0xffffffff
    for b in data:
        c = _CRC[(c ^ b) & 0xff] ^ (c >> 8)
    return c ^ 0xffffffff

def read_man(path):
    with open(path, 'rb') as f:
        raw = f.read()
    if path.endswith('.gz'):
        return subprocess.run(['gzip', '-dc'], input=raw, stdout=subprocess.PIPE, check=True).stdout
    return raw

def parse_name_section(fname):
    base = fname[:-3] if fname.endswith('.gz') else fname
    stem, dot, sec = base.rpartition('.')
    if not dot:
        return base, 1
    m = re.match(r'(\d+)', sec)
    return stem, (int(m.group(1)) if m else 1)

def detect_so(body):
    """Return (tgt_name, tgt_section) if body is purely a .so redirect, else None."""
    real = [ln for ln in body.decode('latin-1').splitlines()
            if ln.strip() and not ln.startswith('.\\"')]
    so = [ln for ln in real if ln.strip().startswith('.so ')]
    if so and len(so) == len(real):
        tgt = so[0].split(None, 1)[1].strip()
        return parse_name_section(os.path.basename(tgt))
    return None

def collect(man_root, lang='en'):
    entries = []
    for d in sorted(glob.glob(os.path.join(man_root, 'share', 'man', 'man[0-9]*'))):
        if not os.path.isdir(d):
            continue
        for fp in sorted(glob.glob(os.path.join(d, '*'))):
            if not os.path.isfile(fp):
                continue
            name, section = parse_name_section(os.path.basename(fp))
            body = read_man(fp)
            so = detect_so(body)
            if so:
                entries.append((name, section, lang, KIND_SO, so))
            else:
                entries.append((name, section, lang, KIND_ROFF, body))
    entries.sort(key=lambda e: (e[0], e[1], e[2]))
    return entries

def s(text):
    bs = text.encode('utf-8')
    return struct.pack('<H', len(bs)) + bs

def build_inner(entries):
    blobs = bytearray()
    index = bytearray()
    for (name, section, lang, kind, data) in entries:
        index += s(name) + struct.pack('<B', section) + s(lang) + struct.pack('<B', kind)
        if kind == KIND_SO:
            tname, tsec = data
            index += s(tname) + struct.pack('<B', tsec)
        else:
            off = len(blobs); blobs += data
            index += struct.pack('<II', off, len(data))
    magic = b'UPMAN' + struct.pack('<B', 1) + struct.pack('<B', 0)  # +version +reserved
    head = magic + struct.pack('<H', len(entries)) + struct.pack('<I', len(index))
    return bytes(head + index + blobs)

def compress(inner, mode):
    if mode == 'none':
        return 0, inner
    if mode == 'zstd':
        return 1, subprocess.run(['zstd', '-19', '-q', '-c'], input=inner,
                                 stdout=subprocess.PIPE, check=True).stdout
    raise SystemExit('mkman: unsupported compression ' + mode)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('man_root'); ap.add_argument('out')
    ap.add_argument('--compression', default='zstd', choices=['zstd', 'none'])
    a = ap.parse_args()
    entries = collect(a.man_root)
    if not entries:
        print("mkman: no man pages found, nothing to embed", file=sys.stderr)
        sys.exit(3)
    inner = build_inner(entries)
    comp_id, payload = compress(inner, a.compression)
    crc = crc32(payload)
    blob = (BEGIN + struct.pack('<B', 1) + struct.pack('<B', comp_id)
            + struct.pack('<I', len(payload)) + payload + struct.pack('<I', crc) + END)
    with open(a.out, 'wb') as f:
        f.write(blob)
    rk = sum(1 for e in entries if e[3] == KIND_ROFF)
    print(f"mkman: entries={len(entries)} (roff={rk} so={len(entries)-rk}) "
          f"inner={len(inner)}B payload={len(payload)}B blob={len(blob)}B", file=sys.stderr)

if __name__ == '__main__':
    main()
