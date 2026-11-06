#!/usr/bin/env python3
"""sha256 of the EXPANDED content of an Android sparse image, streamed (no disk use).
Usage: simg_sha256.py <file.simg>  -> prints "<sha256>  <expanded_bytes>"
Chunk types: 0xCAC1 raw, 0xCAC2 fill, 0xCAC3 don't care (zeros), 0xCAC4 crc32."""
import hashlib, struct, sys
f = open(sys.argv[1], "rb")
hdr = f.read(28)
magic, major, minor, fhs, chs, blk, total_blks, total_chunks, _crc = struct.unpack("<IHHHHIIII", hdr)
if magic != 0xED26FF3A: sys.exit("not a sparse image")
f.seek(fhs)
h = hashlib.sha256(); zero = bytes(1 << 20); out = 0
for _ in range(total_chunks):
    ctype, _r, csz, tsz = struct.unpack("<HHII", f.read(chs)[:12])
    n = csz * blk; data_len = tsz - chs
    if ctype == 0xCAC1:
        left = n
        while left:
            b = f.read(min(left, 1 << 22)); h.update(b); left -= len(b)
    elif ctype == 0xCAC2:
        pat = f.read(4) * (1 << 18); left = n
        while left:
            k = min(left, len(pat)); h.update(pat[:k]); left -= k
    elif ctype == 0xCAC3:
        left = n
        while left:
            k = min(left, len(zero)); h.update(zero[:k]); left -= k
    elif ctype == 0xCAC4:
        f.read(data_len); n = 0
    else:
        sys.exit(f"bad chunk type {ctype:#x}")
    out += n
if out != total_blks * blk: sys.exit(f"size mismatch {out} vs {total_blks*blk}")
print(f"{h.hexdigest()}  {out}")
