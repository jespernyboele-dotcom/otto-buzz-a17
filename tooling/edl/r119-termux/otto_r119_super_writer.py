#!/usr/bin/env python3
# =============================================================================
# OTTO R119 — streaming A17 super writer (R29E method, no disk unpack)
#
# Expands OTTO_A17_super.simg on the fly (never writes the 6 GiB raw image to
# disk) and programs super in 1 MiB stop-and-wait transactions, exactly like
# root_writer_R29E_proven_reference.py did for init_boot_b. Diff mode: every
# 1 MiB is read first and only programmed if it differs from the image:
#   <program 2048 sectors> -> rawmode ACK -> 1 MiB in 64 KiB bulk pieces
#   -> ZLP -> wait terminal ACK -> 1 MiB readback -> byte compare -> ledger.
# The device paces the transfer; nothing is streamed un-ACKed.
#
# Modes:
#   selftest <simg>                     offline: expand + SHA, no USB
#   run <fd> <goco7> <simg> <ledger> <outdir> <confirm>
#       confirm=FLASH_SUPER writes; INSPECT = read-only eMMC inspection
#       (partitions vs backups + super A17/A13 map); else read-only preflight.
# Exit codes: 0 done+verified, 10 preflight ok, 11 inspect done,
#             12 misc dry-run, 13 misc written+verified, 20 session lost (resumable),
#             30+ hard stop (identity/geometry/verify mismatch).
# =============================================================================
import ctypes as C, errno, gzip, hashlib, os, struct, sys, time
from pathlib import Path

SECTOR = 512
CHUNK = 1048576
SUPER_FIRST = 1704960
SUPER_SECTORS = 12582912
SUPER_LAST = SUPER_FIRST + SUPER_SECTORS - 1
SUPER_BYTES = SUPER_SECTORS * SECTOR
NCH = SUPER_BYTES // CHUNK                     # 6144
SIMG_SHA = "e840f520d7baa0f3c32569ef92c7ba33e9b031a409048602a4b178072bfce8b3"
RAW_SHA = "3072c0c6c74c6e223d9cee1e182a01929011115555d9a50cba71891264389150"
GOCO_SHA = "f7799eb9e38177ff7c7776e472b11c0e54c46e0a984232e3705000719cf30bba"
A13_RAW_SHA = "2c85626c189f0f5b1fccf8b4dbd2b92c036ca2ebbc893acf52922bd3f5d932ee"

def expected_sha(img):
    return A13_RAW_SHA if str(img).endswith(".gz") else RAW_SHA

def H(b): return hashlib.sha256(b).hexdigest()
def say(*a): print(*a, flush=True)

# ---------------------------------------------------------------- sparse ----
def sparse_chunks(simg, start_chunk=0):
    """Yield (index, 1 MiB bytes) of the expanded image from start_chunk on."""
    f = open(simg, "rb")
    hdr = f.read(28)
    magic, major, minor, fhs, chs, blk, tblk, tchk, _ = struct.unpack("<IHHHHIIII", hdr)
    if magic != 0xED26FF3A or major != 1: raise RuntimeError("not an Android sparse image")
    if tblk * blk != SUPER_BYTES: raise RuntimeError(f"sparse size {tblk*blk} != super {SUPER_BYTES}")
    f.seek(fhs)
    skip = start_chunk * CHUNK                # output bytes to skip before emitting
    buf = bytearray(); idx = start_chunk
    for _ in range(tchk):
        ch = f.read(chs)
        ctype, _, csz, tsz = struct.unpack("<HHII", ch[:12])
        out_len = csz * blk
        if ctype == 0xCAC1:                   # RAW
            data_pos = f.tell(); f.seek(data_pos + tsz - chs)
            if skip >= out_len: skip -= out_len; continue
            f.seek(data_pos + skip); remaining = out_len - skip; skip = 0
            while remaining:
                need = min(remaining, CHUNK - len(buf))
                d = f.read(need)
                if len(d) != need: raise RuntimeError("short RAW read")
                buf += d; remaining -= need
                if len(buf) == CHUNK: yield idx, bytes(buf); idx += 1; buf = bytearray()
            f.seek(data_pos + tsz - chs)
        elif ctype == 0xCAC2:                 # FILL
            pat = f.read(4)
            if skip >= out_len: skip -= out_len; continue
            remaining = out_len - skip; skip = 0
            while remaining:
                need = min(remaining, CHUNK - len(buf))
                buf += (pat * (need // 4 + 1))[:need]; remaining -= need
                if len(buf) == CHUNK: yield idx, bytes(buf); idx += 1; buf = bytearray()
        elif ctype == 0xCAC3:
            raise RuntimeError("DONT_CARE chunk present; full-partition stream refuses it")
        elif ctype == 0xCAC4:
            f.read(4)
        else:
            raise RuntimeError(f"unknown sparse chunk type {ctype:#x}")
    if buf: raise RuntimeError("expanded size not a multiple of 1 MiB")
    if idx != NCH: raise RuntimeError(f"expanded {idx} chunks, expected {NCH}")

def gzip_chunks(gz, start_chunk=0):
    """Yield (index, 1 MiB bytes) of a gzip'd raw super image (A13 backup)."""
    with gzip.open(gz, "rb") as f:
        for _ in range(start_chunk):
            if len(f.read(CHUNK)) != CHUNK: raise RuntimeError("gzip image shorter than resume point")
        for idx in range(start_chunk, NCH):
            b = f.read(CHUNK)
            if len(b) != CHUNK: raise RuntimeError(f"gzip image short at chunk {idx}")
            yield idx, b
        if f.read(1): raise RuntimeError("gzip image larger than super")

def image_chunks(img, start_chunk=0):
    return gzip_chunks(img, start_chunk) if str(img).endswith(".gz") else sparse_chunks(img, start_chunk)

def selftest(simg):
    h = hashlib.sha256(); t0 = time.time(); n = 0; want = expected_sha(simg)
    for i, b in image_chunks(simg):
        h.update(b); n += 1
        if n % 512 == 0: say(f"SELFTEST {n}/{NCH} chunks")
    got = h.hexdigest()
    say(f"EXPANDED_CHUNKS={n} EXPANDED_SHA256={got} SECONDS={time.time()-t0:.0f}")
    say("SELFTEST=PASS" if got == want else "SELFTEST=FAIL")
    return 0 if got == want else 31

# ------------------------------------------------------------- usbdevfs -----
libc = C.CDLL(None, use_errno=True)
def _IOC(d, t, n, s): return (d << 30) | (ord(t) << 8) | n | (s << 16)
class Ctrl(C.Structure):
    _fields_ = [("bRequestType", C.c_ubyte), ("bRequest", C.c_ubyte), ("wValue", C.c_ushort),
                ("wIndex", C.c_ushort), ("wLength", C.c_ushort), ("timeout", C.c_uint), ("data", C.c_void_p)]
class Bulk(C.Structure):
    _fields_ = [("ep", C.c_uint), ("len", C.c_uint), ("timeout", C.c_uint), ("data", C.c_void_p)]
USBDEVFS_CONTROL = _IOC(3, 'U', 0, C.sizeof(Ctrl)); USBDEVFS_BULK = _IOC(3, 'U', 2, C.sizeof(Bulk))
USBDEVFS_CLAIMINTERFACE = _IOC(2, 'U', 15, C.sizeof(C.c_uint))
USBDEVFS_RELEASEINTERFACE = _IOC(2, 'U', 16, C.sizeof(C.c_uint))

class Link:
    def __init__(self, fd, xmllog):
        self.fd = fd; self.stash = b""; self.xmllog = open(xmllog, "ab")
        # usbfs serves the cached device+config descriptors on read(); this needs
        # no bus traffic. Fall back to GET_DESCRIPTOR control transfers.
        try:
            os.lseek(fd, 0, os.SEEK_SET); cached = os.read(fd, 4096)
        except OSError: cached = b""
        say(f"USBFS_DESCRIPTORS_BYTES={len(cached)} HEAD={cached[:18].hex()}")
        if len(cached) >= 18 + 9 and cached[1] == 1:
            dev = cached[:18]; blob = cached[18:]
        else:
            dev = self.ctrl(1, 0, 18)
            hdr = self.ctrl(2, 0, 9); blob = self.ctrl(2, 0, struct.unpack_from("<H", hdr, 2)[0])
            say(f"CTRL_DEVICE_DESCRIPTOR={dev.hex()}")
        vid, pid = struct.unpack_from("<HH", dev, 8)
        say(f"USB_VID_PID={vid:04x}:{pid:04x}")
        if (vid, pid) != (0x05c6, 0x9008): raise RuntimeError(f"not EDL {vid:04x}:{pid:04x}")
        off = 0; cur = None; eps = []; cands = []
        def close():
            ins = [a for a, t in eps if a & 0x80 and t == 2]; outs = [a for a, t in eps if not a & 0x80 and t == 2]
            if cur is not None and ins and outs: cands.append((cur, ins[0], outs[0]))
        while off + 2 <= len(blob):
            ln, typ = blob[off], blob[off + 1]
            if ln < 2: break
            d = blob[off:off + ln]
            if typ == 4: close(); cur = d[2]; eps = []
            elif typ == 5 and cur is not None: eps.append((d[2], d[3] & 3))
            off += ln
        close()
        if not cands: raise RuntimeError("no bulk endpoints")
        self.iface, self.ep_in, self.ep_out = cands[0]
        self.ioctl(USBDEVFS_CLAIMINTERFACE, C.c_uint(self.iface), "CLAIM")

    def ioctl(self, req, obj, what):
        rc = libc.ioctl(self.fd, req, C.byref(obj))
        if rc < 0: e = C.get_errno(); raise OSError(e, f"{what}: {os.strerror(e)}")
        return rc
    def ctrl(self, dtype, index, length):
        b = C.create_string_buffer(length)
        x = Ctrl(0x80, 0x06, (dtype << 8) | index, 0, length, 3000, C.cast(b, C.c_void_p))
        return bytes(b.raw[:self.ioctl(USBDEVFS_CONTROL, x, "GET_DESCRIPTOR")])
    def release(self):
        try: libc.ioctl(self.fd, USBDEVFS_RELEASEINTERFACE, C.byref(C.c_uint(self.iface)))
        except Exception: pass

    def bw(self, data, timeout=30000):
        total = 0; mv = memoryview(data)
        while total < len(data):
            piece = bytes(mv[total:total + 65536])
            b = C.create_string_buffer(piece, len(piece))
            rc = self.ioctl(USBDEVFS_BULK, Bulk(self.ep_out, len(piece), timeout, C.cast(b, C.c_void_p)), "bulk_write")
            if rc <= 0: raise RuntimeError("zero bulk write")
            total += rc
        return total
    def zlp(self):
        self.ioctl(USBDEVFS_BULK, Bulk(self.ep_out, 0, 5000, C.c_void_p(0)), "bulk_write_zlp")
    def br(self, maxlen=65536, timeout=1500, allow_timeout=False):
        req = max(4096, int(maxlen))
        while True:
            b = C.create_string_buffer(req)
            rc = libc.ioctl(self.fd, USBDEVFS_BULK, C.byref(Bulk(self.ep_in, req, timeout, C.cast(b, C.c_void_p))))
            if rc < 0:
                e = C.get_errno()
                if allow_timeout and e in (errno.ETIMEDOUT, 110): return b""
                if e == errno.ENOMEM and req > 4096: req = max(4096, req // 2); continue
                raise OSError(e, f"bulk_read: {os.strerror(e)}")
            return b.raw[:rc]

    # Firehose XML responses (same parsing rules as R29E).
    def response(self, timeout_s, want_raw):
        pending = self.stash; self.stash = b""; start = time.time()
        while time.time() - start < timeout_s:
            while True:
                end = pending.lower().find(b"</data>")
                if end < 0: break
                end += 7; doc = pending[:end]; pending = pending[end:]
                self.xmllog.write(doc + b"\n"); dlo = doc.lower()
                if b"<response" not in dlo: continue
                ack = b'value="ack"' in dlo or b"value='ack'" in dlo
                nak = b'value="nak"' in dlo or b"value='nak'" in dlo
                raw = b'rawmode="true"' in dlo or b"rawmode='true'" in dlo
                if not (ack or nak): continue
                if not want_raw or raw or nak:
                    self.stash = pending; return ack and not nak, raw
            d = self.br(65536, 750, True)
            if d: pending += d
        self.stash = pending
        return False, False

    def simple(self, xml, timeout_s=20):
        self.bw(xml); ok, _ = self.response(timeout_s, False); return ok

    def program(self, lba, payload):
        xml = (f'<?xml version="1.0" ?><data><program SECTOR_SIZE_IN_BYTES="512" '
               f'num_partition_sectors="{len(payload)//SECTOR}" physical_partition_number="0" '
               f'start_sector="{lba}" /></data>').encode()
        self.stash = b""; self.bw(xml)
        ok, raw = self.response(20, True)
        if not (ok and raw): return "PRE_NO_RAWMODE_ACK"
        if self.bw(payload, 45000) != len(payload): return "SHORT_PAYLOAD"
        self.zlp()
        ok, _ = self.response(30, False)
        return None if ok else "NO_TERMINAL_ACK"

    def read(self, lba, nbytes):
        xml = (f'<?xml version="1.0" ?><data><read SECTOR_SIZE_IN_BYTES="512" '
               f'num_partition_sectors="{nbytes//SECTOR}" physical_partition_number="0" '
               f'start_sector="{lba}" /></data>').encode()
        self.stash = b""; self.bw(xml)
        ok, raw = self.response(20, True)
        if not (ok and raw): return None
        data = bytearray()
        while len(data) < nbytes:
            if self.stash:
                need = nbytes - len(data); data += self.stash[:need]; self.stash = self.stash[need:]; continue
            d = self.br(min(65536, nbytes - len(data)), 5000, True)
            if not d: return None
            need = nbytes - len(data); data += d[:need]
            if len(d) > need: self.stash = d[need:] + self.stash
        ok, _ = self.response(10, False)
        return bytes(data) if ok else None

def sahara_or_firehose(link, goco):
    """Upload goco7 via Sahara; if already in Firehose (no HELLO), reuse it."""
    hello = b""
    for attempt in range(4):                    # first IN after grant can hit EPROTO
        try: hello = link.br(4096, 3000, True); break
        except OSError as e:
            if e.errno != errno.EPROTO or attempt == 3: raise
            say(f"SAHARA_HELLO_RETRY={attempt+1} ({e})"); time.sleep(1)
    if not hello:
        say("SAHARA_HELLO=absent -> probing existing Firehose")
        return "REUSED_FIREHOSE"
    if len(hello) < 24 or struct.unpack_from("<I", hello, 0)[0] != 1:
        if b"<?xml" in hello: link.stash = hello; return "REUSED_FIREHOSE"
        raise RuntimeError("unexpected first packet (not Sahara HELLO)")
    _, _, ver, minver = struct.unpack_from("<IIII", hello, 0)
    link.bw(struct.pack("<12I", 2, 0x30, ver, max(1, min(minver, ver)), 0, 0, 0, 0, 0, 0, 0, 0))
    pdata = goco.read_bytes(); status = None
    while True:
        pkt = link.br(4096, 10000)
        cmd = struct.unpack_from("<I", pkt, 0)[0]
        if cmd == 3: _, _, _, off, n = struct.unpack_from("<IIIII", pkt, 0)
        elif cmd == 0x12: _, _, _, off, n = struct.unpack_from("<IIQQQ", pkt, 0)
        elif cmd == 4: status = struct.unpack_from("<IIII", pkt, 0)[3]; break
        else: raise RuntimeError(f"unexpected Sahara cmd {cmd:#x}")
        link.bw(pdata[off:off + n], 15000)
    if status != 0: raise RuntimeError(f"programmer rejected {status}")
    link.bw(struct.pack("<II", 5, 8)); done = link.br(4096, 10000)
    if len(done) < 8 or struct.unpack_from("<I", done, 0)[0] != 6: raise RuntimeError("Sahara DONE missing")
    quiet = 0; t0 = time.time()                 # drain loader banner
    while time.time() - t0 < 12 and quiet < 4:
        quiet = 0 if link.br(65536, 750, True) else quiet + 1
    return "SAHARA_GOCO7_UPLOADED"

def check_gpt(link):
    hdr = link.read(1, 512)
    if not hdr or hdr[:8] != b"EFI PART": raise RuntimeError("GPT header unreadable")
    elba, nent, esz = struct.unpack_from("<QII", hdr, 72)
    tab = bytearray(); need = ((nent * esz + 511) // 512) * 512; lba = elba
    while len(tab) < need:
        take = min(CHUNK, need - len(tab)); d = link.read(lba, take)
        if d is None: raise RuntimeError("GPT entries unreadable")
        tab += d; lba += take // SECTOR
    parts = []; hits = []
    for i in range(nent):
        e = tab[i * esz:(i + 1) * esz]
        if e[:16] == b"\0" * 16: continue
        first, last, attr = struct.unpack_from("<QQQ", e, 32)
        name = e[56:128].decode("utf-16le", "ignore").split("\0", 1)[0]
        parts.append((name, first, last))
        if name in ("boot_a", "boot_b"):
            # Qualcomm A/B slot bits in the GPT attribute high word.
            say(f"SLOT {name}: attr=0x{attr:016x} priority={(attr>>48)&3} active={(attr>>50)&1} "
                f"retry={(attr>>51)&7} successful={(attr>>54)&1} unbootable={(attr>>55)&1}")
        if name == "super": hits.append((first, last))
    if hits != [(SUPER_FIRST, SUPER_LAST)]: raise RuntimeError(f"GPT super mismatch: {hits}")
    return parts

# --------------------------------------------------------------- inspect ----
VOLATILE = {"misc", "devinfo", "frp", "metadata", "modemst1", "modemst2", "fsg", "fsc",
            "logfs", "logdump", "keystore", "limits", "ssd", "apdp", "dip", "persist", "userdata"}

def read_span(link, lba, nbytes, h=None):
    out = bytearray() if h is None else None; off = 0
    while off < nbytes:
        take = min(CHUNK, nbytes - off)
        d = link.read(lba + off // SECTOR, take)
        if d is None: raise OSError(errno.EIO, f"read failed at lba {lba + off // SECTOR}")
        if h is not None: h.update(d)
        else: out += d
        off += take
    return out

def backup_sha(path, nbytes):
    h = hashlib.sha256(); n = 0
    with (gzip.open(path, "rb") if path.suffix == ".gz" else open(path, "rb")) as f:
        while n < nbytes:
            d = f.read(min(CHUNK, nbytes - n))
            if not d: break
            h.update(d); n += len(d)
    return h.hexdigest(), n

def inspect(link, parts, simg_a17, gz_a13, backups, outdir):
    rep = open(outdir / "R119_INSPECT_REPORT.txt", "w")
    def out(line): say(line); rep.write(line + "\n"); rep.flush()
    out(f"GPT_PARTITIONS={len(parts)}")

    misc = read_span(link, next(f for n, f, l in parts if n == "misc"), 4096)
    cmd = bytes(misc[:32]).split(b"\0", 1)[0].decode("ascii", "replace")
    out(f"MISC_BOOTLOADER_COMMAND='{cmd}'")

    hdr = read_span(link, SUPER_FIRST + 8, 4096)       # LP geometry at super+4096
    out(f"SUPER_LP_GEOMETRY_MAGIC={'OK' if hdr[:4] == bytes.fromhex('67446c61') else hdr[:4].hex()}")

    out("--- physical partitions vs backups (read-only) ---")
    for name, first, last in parts:
        if name in ("super", "userdata"): continue
        nbytes = (last - first + 1) * SECTOR
        bk = next((backups / f"{name}{ext}" for ext in (".img", ".img.gz") if (backups / f"{name}{ext}").exists()), None)
        if bk is None: out(f"PART {name:<20} {nbytes//1024:>8} KiB  NO_BACKUP"); continue
        want, bn = backup_sha(bk, nbytes)
        if bn != nbytes: out(f"PART {name:<20} {nbytes//1024:>8} KiB  BACKUP_SIZE_DIFF ({bn})"); continue
        h = hashlib.sha256(); read_span(link, first, nbytes, h)
        tag = "SAME_AS_BACKUP" if h.hexdigest() == want else ("CHANGED(volatile)" if name in VOLATILE else "CHANGED")
        out(f"PART {name:<20} {nbytes//1024:>8} KiB  {tag}")

    out("--- super content map (1 MiB granularity) ---")
    runs = []; cnt = {"A17": 0, "A13": 0, "OTHER": 0}
    for (i, a17), (_, a13) in zip(sparse_chunks(simg_a17), gzip_chunks(gz_a13)):
        d = link.read(SUPER_FIRST + i * (CHUNK // SECTOR), CHUNK)
        if d is None: raise OSError(errno.EIO, f"super read failed chunk {i}")
        k = "A17" if d == a17 else ("A13" if d == a13 else "OTHER")
        if a17 == a13 and d == a17: k = "A13"           # identical in both images
        cnt[k] += 1
        if runs and runs[-1][0] == k: runs[-1][2] = i
        else: runs.append([k, i, i])
        if (i + 1) % 512 == 0: say(f"SCAN {i+1}/{NCH}")
    for k, a, b in runs: out(f"SUPER_RANGE MiB {a:>5}-{b:<5} {k}")
    out(f"SUPER_SUMMARY A17={cnt['A17']} A13={cnt['A13']} OTHER={cnt['OTHER']} MiB")
    rep.close()
    return 11

# ------------------------------------------------------------------ misc ----
# Android bootloader_message (BCB) in the first 2 KiB of misc:
#   command[32] status[32] recovery[768] stage[32] reserved[1184]
# "boot-recovery" + "recovery\n--fastboot\n" is exactly what `adb reboot
# fastboot` writes: ABL boots recovery and recovery starts fastbootd.
def bcb_show(blob):
    f = lambda a, b: bytes(blob[a:b]).split(b"\0", 1)[0].decode("ascii", "replace").replace("\n", "\\n")
    return f"command='{f(0,32)}' status='{f(32,64)}' recovery='{f(64,832)}' stage='{f(832,864)}'"

def misc_op(link, parts, op, outdir):
    first = next(f for n, f, l in parts if n == "misc")
    cur = bytes(read_span(link, first, 4096))
    (outdir / "MISC_FIRST_4K_BEFORE.bin").write_bytes(cur)
    say(f"MISC_BEFORE {bcb_show(cur)}")
    if op == "fastboot":
        bcb = bytearray(2048)
        bcb[0:13] = b"boot-recovery"
        rec = b"recovery\n--fastboot\n"; bcb[64:64 + len(rec)] = rec
    else:                                       # clear
        bcb = bytearray(2048)
    new = bytes(bcb) + cur[2048:]
    say(f"MISC_TARGET {bcb_show(new)}")
    if os.environ.get("R119_MISC_WRITE") != "YES":
        say("MISC_DRY_RUN (nothing written). Set OTTO_R119_CONFIRM=WRITE_MISC to write.")
        return 12
    err = link.program(first, new)
    if err: say(f"MISC_WRITE_FAIL={err}"); return 20
    rb = bytes(read_span(link, first, 4096))
    if rb != new: say("MISC_VERIFY=MISMATCH"); return 35
    say(f"MISC_AFTER {bcb_show(rb)}")
    say("MISC_WRITE=VERIFIED")
    return 13

# ---------------------------------------------------------------- ledger ----
def ledger_next(ledger):
    try:
        for line in ledger.read_text().splitlines():
            if line.startswith("NEXT_CHUNK="): return int(line.split("=", 1)[1])
    except FileNotFoundError: pass
    return 0
def ledger_set(ledger, nxt, extra=""):
    tmp = ledger.with_suffix(".tmp")
    tmp.write_text(f"NEXT_CHUNK={nxt}\nTOTAL_CHUNKS={NCH}\nUPDATED={time.strftime('%Y-%m-%dT%H:%M:%S')}\n{extra}")
    os.replace(tmp, ledger)

def run(fd, goco, simg, ledger, outdir, confirm):
    outdir.mkdir(parents=True, exist_ok=True)
    if H(goco.read_bytes()) != GOCO_SHA: say("FAIL=GOCO7_SHA"); return 32
    live = confirm == "FLASH_SUPER"
    link = Link(fd, outdir / "R119_FIREHOSE_XML.log")
    try:
        say(f"ENTRY={sahara_or_firehose(link, goco)}")
        if not link.simple(b'<?xml version="1.0" ?><data><nop /></data>'): say("FAIL=NOP_NO_ACK"); return 20
        cfg = (b'<?xml version="1.0" ?><data><configure MemoryName="eMMC" Verbose="0" AlwaysValidate="0" '
               b'MaxDigestTableSizeInBytes="2048" MaxPayloadSizeToTargetInBytes="1048576" '
               b'ZlpAwareHost="1" SkipStorageInit="0" /></data>')
        if not link.simple(cfg): say("FAIL=CONFIGURE_NO_ACK"); return 20
        say("FIREHOSE=NOP_ACK CONFIGURE_ACK")
        parts = check_gpt(link); say(f"GPT_SUPER=OK first={SUPER_FIRST} last={SUPER_LAST}")
        if confirm == "STATUS":
            first = next(f for n, f, l in parts if n == "misc")
            say(f"MISC_NOW {bcb_show(bytes(read_span(link, first, 4096)))}")
            return 14
        if confirm in ("MISC_FASTBOOT", "MISC_CLEAR"):
            return misc_op(link, parts, "fastboot" if confirm == "MISC_FASTBOOT" else "clear", outdir)
        if confirm == "INSPECT":
            return inspect(link, parts, Path(os.environ["R119_A17"]), Path(os.environ["R119_A13"]),
                           Path(os.environ["R119_BACKUPS"]), outdir)

        start = ledger_next(ledger)
        say(f"RESUME_FROM_CHUNK={start}/{NCH}")
        if not live:
            d = link.read(SUPER_FIRST + start * (CHUNK // SECTOR), CHUNK)
            say(f"PREFLIGHT_READ_1MiB={'OK' if d else 'FAIL'}")
            say("PREFLIGHT=OK (no writes). Set OTTO_R119_CONFIRM=FLASH_SUPER to write.")
            return 10 if d else 20

        # Diff mode: OTTO's eMMC still holds data, so each 1 MiB is read first
        # and only programmed when it differs from the target image.
        t0 = time.time(); done = 0; written = 0; same = 0
        if start < NCH:
            for i, payload in image_chunks(simg, start):
                lba = SUPER_FIRST + i * (CHUNK // SECTOR)
                cur = link.read(lba, CHUNK)
                if cur is None: say(f"CHUNK_FAIL={i} STAGE=PREREAD REASON=NO_DATA"); return 20
                if cur == payload:
                    status = "SAME"; same += 1
                else:
                    err = link.program(lba, payload)
                    if err: say(f"CHUNK_FAIL={i} STAGE=PROGRAM REASON={err}"); return 20
                    rb = link.read(lba, CHUNK)
                    if rb is None: say(f"CHUNK_FAIL={i} STAGE=READBACK REASON=NO_DATA"); return 20
                    if rb != payload: say(f"CHUNK_FAIL={i} STAGE=VERIFY REASON=MISMATCH"); return 33
                    status = "WRITTEN"; written += 1
                ledger_set(ledger, i + 1); done += 1
                if done % 16 == 0 or i + 1 == NCH:
                    el = time.time() - t0
                    say(f"PROGRESS {i+1}/{NCH} chunks ({100*(i+1)/NCH:.1f}%) written={written} same={same} last={status} "
                        f"{done/el:.2f} MiB/s elapsed={el:.0f}s eta={(NCH-i-1)/(done/el):.0f}s")

        say("FINAL_VERIFY=reading full super (1 MiB reads)")
        h = hashlib.sha256()
        for i in range(NCH):
            d = link.read(SUPER_FIRST + i * (CHUNK // SECTOR), CHUNK)
            if d is None: say(f"FINAL_VERIFY_READ_FAIL={i}"); return 20
            h.update(d)
            if (i + 1) % 512 == 0: say(f"VERIFY {i+1}/{NCH}")
        got = h.hexdigest()
        say(f"FINAL_SUPER_SHA256={got}")
        if got != expected_sha(simg):
            ledger_set(ledger, 0, "NOTE=final hash mismatch; full re-pass required\n")
            say("RESULT=FINAL_HASH_MISMATCH"); return 34
        ledger_set(ledger, NCH, f"FINAL_SHA256={got}\nRESULT=FLASH_PASS\n")
        say(f"RESULT=FLASH_PASS ({simg.name} written to super and fully SHA-verified)")
        return 0
    except OSError as e:
        say(f"SESSION_LOST={e}"); return 20
    finally:
        link.xmllog.close(); link.release()

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "selftest":
        sys.exit(selftest(sys.argv[2]))
    if len(sys.argv) == 8 and sys.argv[1] == "run":
        sys.exit(run(int(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]),
                     Path(sys.argv[5]), Path(sys.argv[6]), sys.argv[7]))
    say(__doc__ or "usage: selftest <simg> | run <fd> <goco7> <simg> <ledger> <outdir> <confirm>")
    sys.exit(2)
