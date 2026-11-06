#!/usr/bin/env python3
# =============================================================================
# OTTO R119 for Windows — streaming A17 super writer over pyusb/libusb
#
# Same method as the Termux R119 (and root_writer_R29E for init_boot_b):
# sparse image expanded 1 MiB at a time in memory; per 1 MiB: read, skip if
# identical, else <program> -> rawmode ACK -> 64 KiB pieces -> ZLP -> terminal
# ACK -> readback -> compare. Ledger file lets a lost session resume.
#
# Needs: Python 3, `pip install pyusb libusb-package`, and the WinUSB driver
# on the "QUSB__BULK" (05C6:9008) device via Zadig.
#
# FINAL3 copy (2026-11-01): flashes OTTO_A17_FINAL3_super.simg from this folder; goco7.bin in the folder above.
# Writes super only (slot _b layout, same as FINAL). Never OTA again.
# Usage (from this folder):
#   python otto_r119_win_final3.py selftest          offline sparse+SHA check, no USB
#   python otto_r119_win_final3.py preflight         EDL + loader + GPT check, no writes
#   python otto_r119_win_final3.py flash             write A17 super (asks to confirm)
#   python otto_r119_win_final3.py wipe-userdata     zero first 64 MiB of userdata (asks)
# =============================================================================
import hashlib, os, struct, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
GOCO = HERE.parent / "goco7.bin"   # FINAL: the loader stays in the otto folder
SIMG = HERE / "OTTO_A17_FINAL3_super.simg"
LEDGER = HERE / "R119_LEDGER_a17_final3.txt"
LOG = HERE / "R119_WIN_LOG.txt"

SECTOR = 512
CHUNK = 1048576
SUPER_FIRST = 1704960
SUPER_SECTORS = 12582912
SUPER_LAST = SUPER_FIRST + SUPER_SECTORS - 1
SUPER_BYTES = SUPER_SECTORS * SECTOR
NCH = SUPER_BYTES // CHUNK
RAW_SHA = "5cac116531d47d02a36348738f2748f9021a2511d2e8ac1451b18157a804c576"   # OTTO_A17_FINAL3 (2026-11-01, rebuild: launcher v18 + GPS satellites)
GOCO_SHA = "f7799eb9e38177ff7c7776e472b11c0e54c46e0a984232e3705000719cf30bba"

def say(*a):
    line = " ".join(str(x) for x in a)
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f: f.write(time.strftime("%H:%M:%S ") + line + "\n")

# ---------------------------------------------------------------- sparse ----
def sparse_chunks(simg, start_chunk=0):
    """Yield (index, 1 MiB bytes) of the expanded image from start_chunk on."""
    f = open(simg, "rb")
    magic, major, _, fhs, chs, blk, tblk, tchk, _ = struct.unpack("<IHHHHIIII", f.read(28))
    if magic != 0xED26FF3A or major != 1: raise RuntimeError("not an Android sparse image")
    if tblk * blk != SUPER_BYTES: raise RuntimeError(f"sparse size {tblk*blk} != super {SUPER_BYTES}")
    f.seek(fhs)
    skip = start_chunk * CHUNK; buf = bytearray(); idx = start_chunk
    for _ in range(tchk):
        ctype, _, csz, tsz = struct.unpack("<HHII", f.read(chs)[:12])
        out_len = csz * blk
        if ctype == 0xCAC1:                   # RAW
            data_pos = f.tell()
            if skip >= out_len: skip -= out_len; f.seek(data_pos + tsz - chs); continue
            f.seek(data_pos + skip); remaining = out_len - skip; skip = 0
            while remaining:
                need = min(remaining, CHUNK - len(buf)); d = f.read(need)
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
        elif ctype == 0xCAC3: raise RuntimeError("DONT_CARE chunk present")
        elif ctype == 0xCAC4: f.read(4)
        else: raise RuntimeError(f"unknown sparse chunk type {ctype:#x}")
    if buf or idx != NCH: raise RuntimeError(f"expanded {idx} chunks, expected {NCH}")

def selftest():
    h = hashlib.sha256(); n = 0
    for _, b in sparse_chunks(SIMG):
        h.update(b); n += 1
        if n % 1024 == 0: say(f"SELFTEST {n}/{NCH}")
    ok = h.hexdigest() == RAW_SHA
    say(f"EXPANDED_SHA256={h.hexdigest()}"); say("SELFTEST=PASS" if ok else "SELFTEST=FAIL")
    return 0 if ok else 31

# ------------------------------------------------------------------- usb ----
class SessionLost(Exception): pass

class Link:
    def __init__(self):
        import usb.core, usb.util, libusb_package
        self.usb = usb
        self.dev = libusb_package.find(idVendor=0x05C6, idProduct=0x9008)
        if self.dev is None: raise SessionLost("no 05c6:9008 device")
        try: self.dev.set_configuration()
        except usb.core.USBError: pass
        intf = self.dev.get_active_configuration()[(0, 0)]
        pick = lambda d: usb.util.find_descriptor(intf, custom_match=lambda e:
            usb.util.endpoint_direction(e.bEndpointAddress) == d and
            usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
        self.ep_in = pick(usb.util.ENDPOINT_IN); self.ep_out = pick(usb.util.ENDPOINT_OUT)
        if not self.ep_in or not self.ep_out: raise SessionLost("no bulk endpoints")
        self.stash = b""

    def bw(self, data, timeout=30000):
        try:
            for off in range(0, len(data), 65536):
                self.ep_out.write(data[off:off + 65536], timeout)
        except self.usb.core.USBError as e: raise SessionLost(f"bulk_write: {e}")
        return len(data)
    def zlp(self):
        try: self.ep_out.write(b"", 5000)
        except self.usb.core.USBError as e: raise SessionLost(f"zlp: {e}")
    def br(self, maxlen=65536, timeout=1500, allow_timeout=False):
        try: return bytes(self.ep_in.read(max(4096, maxlen), timeout))
        except self.usb.core.USBTimeoutError:
            if allow_timeout: return b""
            raise SessionLost("bulk_read timeout")
        except self.usb.core.USBError as e: raise SessionLost(f"bulk_read: {e}")

    def response(self, timeout_s, want_raw):
        pending = self.stash; self.stash = b""; start = time.time()
        while time.time() - start < timeout_s:
            while True:
                end = pending.lower().find(b"</data>")
                if end < 0: break
                end += 7; doc = pending[:end]; pending = pending[end:]; dlo = doc.lower()
                if b"<response" not in dlo: continue
                ack = b'value="ack"' in dlo; nak = b'value="nak"' in dlo
                raw = b'rawmode="true"' in dlo
                if not (ack or nak): continue
                if not want_raw or raw or nak:
                    self.stash = pending; return ack and not nak, raw
            d = self.br(65536, 750, True)
            if d: pending += d
        self.stash = pending
        return False, False
    def simple(self, xml):
        self.bw(xml); return self.response(20, False)[0]

    def program(self, lba, payload):
        xml = (f'<?xml version="1.0" ?><data><program SECTOR_SIZE_IN_BYTES="512" '
               f'num_partition_sectors="{len(payload)//SECTOR}" physical_partition_number="0" '
               f'start_sector="{lba}" /></data>').encode()
        self.stash = b""; self.bw(xml)
        ok, raw = self.response(20, True)
        if not (ok and raw): return "PRE_NO_RAWMODE_ACK"
        self.bw(payload, 45000); self.zlp()
        return None if self.response(30, False)[0] else "NO_TERMINAL_ACK"

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
        return bytes(data) if self.response(10, False)[0] else None

    def close(self):
        try: self.usb.util.dispose_resources(self.dev)
        except Exception: pass

def enter_firehose(link):
    hello = link.br(4096, 3000, True)
    if not hello: say("SAHARA_HELLO=absent -> reusing running Firehose"); return
    if struct.unpack_from("<I", hello, 0)[0] != 1:
        if b"<?xml" in hello: link.stash = hello; return
        raise SessionLost("unexpected first packet")
    _, _, ver, minver = struct.unpack_from("<IIII", hello, 0)
    link.bw(struct.pack("<12I", 2, 0x30, ver, max(1, min(minver, ver)), 0, 0, 0, 0, 0, 0, 0, 0))
    pdata = GOCO.read_bytes(); status = None
    while True:
        pkt = link.br(4096, 10000)
        cmd = struct.unpack_from("<I", pkt, 0)[0]
        if cmd == 3: _, _, _, off, n = struct.unpack_from("<IIIII", pkt, 0)
        elif cmd == 0x12: _, _, _, off, n = struct.unpack_from("<IIQQQ", pkt, 0)
        elif cmd == 4: status = struct.unpack_from("<IIII", pkt, 0)[3]; break
        else: raise SessionLost(f"unexpected Sahara cmd {cmd:#x}")
        link.bw(pdata[off:off + n], 15000)
    if status != 0: raise RuntimeError(f"programmer rejected {status}")
    link.bw(struct.pack("<II", 5, 8)); link.br(4096, 10000)
    quiet = 0; t0 = time.time()
    while time.time() - t0 < 12 and quiet < 4:
        quiet = 0 if link.br(65536, 750, True) else quiet + 1
    say("SAHARA=goco7 uploaded")

def configure(link):
    if not link.simple(b'<?xml version="1.0" ?><data><nop /></data>'): raise SessionLost("NOP no ACK")
    cfg = (b'<?xml version="1.0" ?><data><configure MemoryName="eMMC" Verbose="0" AlwaysValidate="0" '
           b'MaxDigestTableSizeInBytes="2048" MaxPayloadSizeToTargetInBytes="1048576" '
           b'ZlpAwareHost="1" SkipStorageInit="0" /></data>')
    if not link.simple(cfg): raise SessionLost("configure no ACK")
    hdr = link.read(1, 512)
    if not hdr or hdr[:8] != b"EFI PART": raise SessionLost("GPT header unreadable")
    elba, nent, esz = struct.unpack_from("<QII", hdr, 72)
    tab = link.read(elba, ((nent * esz + 511) // 512) * 512)
    if tab is None: raise SessionLost("GPT entries unreadable")
    hits = []
    for i in range(nent):
        e = tab[i * esz:(i + 1) * esz]
        if e[:16] == b"\0" * 16: continue
        first, last = struct.unpack_from("<QQ", e, 32)
        if e[56:128].decode("utf-16le", "ignore").split("\0", 1)[0] == "super": hits.append((first, last))
    if hits != [(SUPER_FIRST, SUPER_LAST)]: raise RuntimeError(f"GPT super mismatch {hits}")
    say("FIREHOSE=OK GPT_SUPER=OK")
    for i in range(nent):
        e = tab[i * esz:(i + 1) * esz]
        if e[56:128].decode("utf-16le", "ignore").split("\0", 1)[0] == "userdata":
            link.userdata = struct.unpack_from("<QQ", e, 32)
    say(f"GPT_USERDATA={getattr(link, 'userdata', None)}")

# Equivalent of `fastboot erase userdata` from the migration plan: zero the start
# of userdata so fs_mgr sees it as wiped and formats it with a fresh key.
WIPE_MIB = 64
def wipe_userdata(link):
    first, last = getattr(link, "userdata", (None, None))
    if first is None or (last - first + 1) * SECTOR < 100 * (1 << 30):
        raise RuntimeError(f"userdata not found or implausibly small: {first}..{last}")
    zero = bytes(CHUNK)
    for i in range(WIPE_MIB):
        lba = first + i * (CHUNK // SECTOR)
        err = link.program(lba, zero)
        if err: raise SessionLost(f"wipe program {i}: {err}")
        if link.read(lba, CHUNK) != zero: raise SessionLost(f"wipe verify {i}")
    say(f"RESULT=USERDATA_WIPED first {WIPE_MIB} MiB zeroed+verified (lba {first})")

# ---------------------------------------------------------------- ledger ----
def ledger_next():
    try:
        for line in LEDGER.read_text().splitlines():
            if line.startswith("NEXT_CHUNK="): return int(line.split("=", 1)[1])
    except FileNotFoundError: pass
    return 0
def ledger_set(n, extra=""):
    tmp = LEDGER.with_suffix(".tmp")
    tmp.write_text(f"NEXT_CHUNK={n}\nTOTAL_CHUNKS={NCH}\nUPDATED={time.strftime('%Y-%m-%dT%H:%M:%S')}\n{extra}")
    os.replace(tmp, LEDGER)

def session(live):
    link = Link()
    try:
        enter_firehose(link); configure(link)
        if live == "wipe":
            wipe_userdata(link); return "wiped"
        start = ledger_next(); say(f"RESUME_FROM_CHUNK={start}/{NCH}")
        if not live:
            ok = link.read(SUPER_FIRST + start * (CHUNK // SECTOR), CHUNK) is not None
            say("PREFLIGHT=OK (no writes)" if ok else "PREFLIGHT=READ_FAIL"); return "preflight"
        t0 = time.time(); done = written = same = 0
        if start < NCH:
            for i, payload in sparse_chunks(SIMG, start):
                lba = SUPER_FIRST + i * (CHUNK // SECTOR)
                cur = link.read(lba, CHUNK)
                if cur is None: raise SessionLost(f"pre-read chunk {i}")
                if cur == payload: same += 1
                else:
                    err = link.program(lba, payload)
                    if err: raise SessionLost(f"program chunk {i}: {err}")
                    rb = link.read(lba, CHUNK)
                    if rb is None: raise SessionLost(f"readback chunk {i}")
                    if rb != payload: raise RuntimeError(f"VERIFY MISMATCH chunk {i}")
                    written += 1
                ledger_set(i + 1); done += 1
                if done % 32 == 0 or i + 1 == NCH:
                    el = time.time() - t0
                    say(f"PROGRESS {i+1}/{NCH} ({100*(i+1)/NCH:.1f}%) written={written} same={same} "
                        f"{done/el:.1f} MiB/s eta={(NCH-i-1)/(done/el)/60:.0f} min")
        say("FINAL_VERIFY: reading all of super")
        h = hashlib.sha256()
        for i in range(NCH):
            d = link.read(SUPER_FIRST + i * (CHUNK // SECTOR), CHUNK)
            if d is None: raise SessionLost(f"final verify read {i}")
            h.update(d)
            if (i + 1) % 1024 == 0: say(f"VERIFY {i+1}/{NCH}")
        if h.hexdigest() != RAW_SHA:
            say(f"FINAL_SHA={h.hexdigest()} MISMATCH"); ledger_set(0, "NOTE=final hash mismatch\n")
            return "mismatch"
        ledger_set(NCH, f"FINAL_SHA256={RAW_SHA}\nRESULT=FLASH_PASS\n")
        say("RESULT=FLASH_PASS  A17 super written and fully SHA-verified"); return "pass"
    finally:
        link.close()

def main(mode):
    if mode == "selftest": return selftest()
    for p in (GOCO, SIMG):
        if not p.exists(): say(f"MISSING {p.name} (put it next to this script)"); return 4
    if hashlib.sha256(GOCO.read_bytes()).hexdigest() != GOCO_SHA: say("goco7.bin SHA mismatch"); return 5
    live = {"flash": True, "wipe-userdata": "wipe"}.get(mode, False)
    if live is True and input("Skriv FLASH for at skrive A17 til OTTO's super: ").strip() != "FLASH":
        say("Afbrudt."); return 1
    if live == "wipe" and input("Skriv SLET for at slette OTTO's gamle userdata: ").strip() != "SLET":
        say("Afbrudt."); return 1
    for s in range(1, 41):
        say(f"--- SESSION {s}  NEXT_CHUNK={ledger_next()} --- (venter paa OTTO i EDL 05c6:9008)")
        t0 = time.time()
        while True:
            try: res = session(live); break
            except SessionLost as e:
                if "no 05c6:9008" in str(e) and time.time() - t0 < 900: time.sleep(2); continue
                say(f"SESSION_LOST: {e}  -> saet OTTO i EDL igen; fortsaetter fra ledger")
                res = None; time.sleep(5); break
        if res in ("pass", "wiped"): return 0
        if res == "preflight": return 10
        if res == "mismatch": return 34
    return 20

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("selftest", "preflight", "flash", "wipe-userdata"):
        print("brug: py otto_r119_win_final3.py selftest | preflight | flash | wipe-userdata"); sys.exit(2)
    try: sys.exit(main(mode))
    except KeyboardInterrupt: say("Stoppet (Ctrl-C). Ledger bevaret."); sys.exit(130)
