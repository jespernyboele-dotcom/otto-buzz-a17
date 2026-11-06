#!/usr/bin/env python3
# =============================================================================
# OTTO RESCUE (2026-10-25) — after the OTA1 brick. READ-ONLY.
#
# Uses the EDL link from ..\OTTO_A17_FINAL\otto_r119_win_final.py (same loader, same
# Firehose code). Writes NOTHING to OTTO: only <read> commands are sent.
#
#   py otto_rescue.py diagnose     read-only state dump (below)
#   py otto_rescue.py setslot-b    = fastboot set_active b + snapshot-update cancel (asks "SLOT B")
#   py otto_rescue.py undo         puts GPT + misc back exactly as in DIAG_20261025_191728 (asks "UNDO")
#
# setslot-b/undo write only three things, each only if it is byte-identical to the diagnose dump
# (or already done): backup GPT, primary GPT (slot flags + type GUIDs, CRCs), 1 sector of misc
# (Virtual A/B merge status SNAPSHOTTED -> CANCELLED). Nothing else: no firmware, no super, no userdata.
#
# Saves to DIAG_<time>\ next to this script:
#   partitions.txt   every GPT entry: lba range, type GUID, slot attributes
#   slots.txt        per _a/_b pair: attributes, type GUIDs, sha256 of _a and _b, SAME/DIFF
#   gpt_primary.bin, gpt_backup.bin   raw GPT (header + entries) for building the slot fix
#   misc.img, devinfo.img, metadata.img, super_head.img (first 1 MiB of super)
# Copy the whole DIAG_ folder back to the phone: Download\qfil\otto\OTTO_RESCUE
# =============================================================================
import hashlib, importlib.util, struct, sys, time, uuid, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
if not Path(__file__).read_bytes().rstrip().endswith(b"# END otto_rescue.py"):   # MTP copies can be cut short
    print("FEJL: otto_rescue.py er ikke kopieret helt til pc'en. Kopier den igen fra telefonen."); sys.exit(3)
spec = importlib.util.spec_from_file_location("fb", HERE.parent / "OTTO_A17_FINAL" / "otto_r119_win_final.py")
fb = importlib.util.module_from_spec(spec); spec.loader.exec_module(fb)
fb.LOG = HERE / "RESCUE_LOG.txt"
say, SECTOR, CHUNK = fb.say, fb.SECTOR, fb.CHUNK
DUMP = {"misc": 4 << 20, "devinfo": 4 << 20, "metadata": 64 << 20}   # dumped if not larger than this

def read_all(link, first, nbytes, h=None, out=None):
    """Read nbytes from lba first in 1 MiB pieces into a hash and/or a file."""
    done = 0
    while done < nbytes:
        n = min(CHUNK, nbytes - done)
        d = link.read(first + done // SECTOR, n)
        if d is None: raise fb.SessionLost(f"read lba {first + done // SECTOR}")
        if h: h.update(d)
        if out: out.write(d)
        done += n

def gpt(link, hdr_lba):
    hdr = link.read(hdr_lba, SECTOR)
    if not hdr or hdr[:8] != b"EFI PART": raise fb.SessionLost(f"GPT header at {hdr_lba} unreadable")
    alt = struct.unpack_from("<Q", hdr, 32)[0]
    elba, nent, esz = struct.unpack_from("<QII", hdr, 72)
    tab = link.read(elba, ((nent * esz + 511) // 512) * 512)
    if tab is None: raise fb.SessionLost("GPT entries unreadable")
    parts = []
    for i in range(nent):
        e = tab[i * esz:(i + 1) * esz]
        if e[:16] == b"\0" * 16: continue
        first, last, attr = struct.unpack_from("<QQQ", e, 32)
        parts.append(dict(i=i, name=e[56:128].decode("utf-16le", "ignore").split("\0", 1)[0],
                          type=str(uuid.UUID(bytes_le=e[:16])), first=first, last=last, attr=attr))
    return hdr, tab, alt, parts

def attrs(a):
    # Qualcomm ABL bit layout: priority 48-49, active 50, retry 51-53, successful 54, unbootable 55
    return (f"attr={a:#018x} prio={(a >> 48) & 3} active={(a >> 50) & 1} retry={(a >> 51) & 7} "
            f"ok={(a >> 54) & 1} unbootable={(a >> 55) & 1}")

def diagnose(link):
    out = HERE / time.strftime("DIAG_%Y%m%d_%H%M%S"); out.mkdir()
    hdr, tab, alt, parts = gpt(link, 1)
    (out / "gpt_primary.bin").write_bytes(hdr + tab)
    bhdr, btab, _, bparts = gpt(link, alt)
    (out / "gpt_backup.bin").write_bytes(bhdr + btab)
    say(f"GPT primary {len(parts)} entries, backup at lba {alt} {len(bparts)} entries, "
        f"{'SAME' if [(p['name'], p['type'], p['attr']) for p in parts] == [(p['name'], p['type'], p['attr']) for p in bparts] else 'DIFFERENT'}")
    with open(out / "partitions.txt", "w") as f:
        for p in parts:
            f.write(f"{p['i']:3} {p['name']:24} {p['first']:>10}-{p['last']:<10} {p['type']} {attrs(p['attr'])}\n")
    by = {p["name"]: p for p in parts}
    pairs = sorted(n[:-2] for n in by if n.endswith("_a") and n[:-2] + "_b" in by)
    with open(out / "slots.txt", "w") as f:
        for base in pairs:
            row = []
            for s in ("_a", "_b"):
                p = by[base + s]; h = hashlib.sha256()
                read_all(link, p["first"], (p["last"] - p["first"] + 1) * SECTOR, h=h)
                row.append((p, h.hexdigest()))
            same = "SAME" if row[0][1] == row[1][1] else "DIFF"
            line = f"{base:16} {same}"
            for (p, hx), s in zip(row, ("_a", "_b")):
                line += f"\n    {s} {p['type']} {attrs(p['attr'])} sha={hx}"
            f.write(line + "\n"); say(f"SLOT {base:16} {same}  a:{attrs(row[0][0]['attr'])[24:]}  b:{attrs(row[1][0]['attr'])[24:]}")
    for name, limit in list(DUMP.items()) + [("super", 1 << 20)]:
        p = by.get(name)
        if not p: say(f"DUMP {name}: not in GPT"); continue
        n = min((p["last"] - p["first"] + 1) * SECTOR, limit)
        fn = "super_head.img" if name == "super" else f"{name}.img"
        with open(out / fn, "wb") as f: read_all(link, p["first"], n, out=f)
        say(f"DUMP {fn} {n} B")
    say(f"RESULT=DIAG_DONE (no writes)  -> copy {out.name} to the phone: Download\\qfil\\otto\\OTTO_RESCUE")

# ------------------------------------------------------------ setslot-b ----
DIAG = HERE / "DIAG_20261025_191728"
DIAG_SHA = {"gpt_primary.bin": "c16b8f4798336c60771afdc4ea3758562e749fff089628ed7c1a17ba4cde5b13",
            "gpt_backup.bin": "9c800000498a3101b30ebd46129da0968509a05ac79617f4df1d8fe4cc4187c3",
            "misc.img": "15b99e6421751c03820bdf8302e4dac853a382620ae363651c27e823a7712867"}
INACTIVE = uuid.UUID("77036cd4-03d5-42bb-8ed1-37e5a88baa34").bytes_le   # QTI type GUID of the inactive slot
VAB_OFF = 0x8000                       # misc_virtual_ab_message: ver, magic 0x56740ab0, merge_status, source_slot
SNAPSHOTTED, CANCELLED = 2, 4

def slot_b(blob):
    """GPT (header + entries) with _b active: what ABL's set_active b writes."""
    hdr, tab = bytearray(blob[:SECTOR]), bytearray(blob[SECTOR:])
    hs = struct.unpack_from("<I", hdr, 12)[0]; _, nent, esz = struct.unpack_from("<QII", hdr, 72)
    idx = {tab[i*esz+56:i*esz+128].decode("utf-16le", "ignore").split("\0", 1)[0]: i * esz
           for i in range(nent) if tab[i*esz:i*esz+16] != b"\0" * 16}
    for n in idx:
        if not n.endswith("_a") or n[:-2] + "_b" not in idx: continue
        oa, ob = idx[n], idx[n[:-2] + "_b"]
        aa, ab = struct.unpack_from("<Q", tab, oa + 48)[0], struct.unpack_from("<Q", tab, ob + 48)[0]
        if n == "vbmeta_system_a": na, nb = aa & ~(1 << 50), ab | (1 << 50)   # only the active bit is used
        else: na, nb = (aa & ~(0xFF << 48)) | (0x80 << 48), (ab & ~(0xFF << 48)) | (0x7F << 48)
        struct.pack_into("<Q", tab, oa + 48, na); struct.pack_into("<Q", tab, ob + 48, nb)
        if tab[ob:ob + 16] == INACTIVE:           # eMMC: PBL/XBL find the active copy by type GUID
            tab[oa:oa + 16], tab[ob:ob + 16] = tab[ob:ob + 16], tab[oa:oa + 16]
    struct.pack_into("<I", hdr, 88, zlib.crc32(bytes(tab[:nent * esz])))
    hdr[16:20] = bytes(4); struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr[:hs])))
    return bytes(hdr + tab)

def regions():
    """[(name, [(lba, original bytes, new bytes)])] in write order for setslot-b."""
    for f, h in DIAG_SHA.items():
        if hashlib.sha256((DIAG / f).read_bytes()).hexdigest() != h: raise RuntimeError(f"{DIAG.name}\\{f} SHA mismatch")
    out = []
    for f in ("gpt_backup.bin", "gpt_primary.bin"):
        old = (DIAG / f).read_bytes(); new = slot_b(old)
        me, elba = struct.unpack_from("<Q", old, 24)[0], struct.unpack_from("<Q", old, 72)[0]
        out.append((f[:-4], [(elba, old[SECTOR:], new[SECTOR:]), (me, old[:SECTOR], new[:SECTOR])]))
    misc = next(p for p in gpt_parts_from(DIAG / "gpt_primary.bin") if p["name"] == "misc")
    old = (DIAG / "misc.img").read_bytes()[VAB_OFF:VAB_OFF + SECTOR]
    if old[:7] != bytes([2, 0xB0, 0x0A, 0x74, 0x56, SNAPSHOTTED, 1]): raise RuntimeError("misc VAB message not SNAPSHOTTED/_b")
    new = old[:5] + bytes([CANCELLED]) + old[6:]
    out.append(("misc", [(misc["first"] + VAB_OFF // SECTOR, old, new)]))
    return out

def gpt_parts_from(path):
    b = path.read_bytes(); _, nent, esz = struct.unpack_from("<QII", b, 72)
    for i in range(nent):
        e = b[SECTOR + i*esz:SECTOR + (i+1)*esz]
        if e[:16] != b"\0" * 16:
            yield dict(name=e[56:128].decode("utf-16le", "ignore").split("\0", 1)[0], first=struct.unpack_from("<Q", e, 32)[0])

def apply(link, undo):
    plan = regions()
    if undo: plan = [(n, [(lba, new, old) for lba, old, new in parts]) for n, parts in reversed(plan)]
    curs = []
    for name, parts in plan:                  # check everything before the first write
        cur = [link.read(lba, len(old)) for lba, old, _ in parts]
        if None in cur: raise fb.SessionLost(f"read {name}")
        if not all(c in (old, new) for c, (_, old, new) in zip(cur, parts)):
            raise RuntimeError(f"{name} on OTTO is neither the diagnose state nor the fixed state -> NOTHING written, stop and ask Claude")
        curs.append(cur)
    for (name, parts), cur in zip(plan, curs):
        if all(c == new for c, (_, _, new) in zip(cur, parts)): say(f"{name}: already done"); continue
        for c, (lba, _, new) in zip(cur, parts):   # GPT: entries first, header last
            if c == new: continue                  # done before a lost session
            err = link.program(lba, new)
            if err: raise fb.SessionLost(f"program {name} lba {lba}: {err}")
            if link.read(lba, len(new)) != new: raise RuntimeError(f"VERIFY MISMATCH {name} lba {lba}")
        say(f"{name}: written + verified")
    say("RESULT=UNDO_DONE  GPT + misc are back as in the diagnose" if undo else
        "RESULT=SLOT_B_DONE  _b active, _a unbootable, OTA update cancelled - give OTTO normal power")

def main(mode):
    if mode in ("setslot-b", "undo"):
        regions()                             # fail on a bad DIAG copy before asking
        word = "SLOT B" if mode == "setslot-b" else "UNDO"
        if input(f"Skriv {word} for at skrive til OTTO's partitionstabel og misc: ").strip() != word:
            say("Afbrudt."); return 1
    if hashlib.sha256(fb.GOCO.read_bytes()).hexdigest() != fb.GOCO_SHA: say("goco7.bin SHA mismatch"); return 5
    say(f"--- RESCUE {mode} --- venter paa OTTO i EDL 05c6:9008")
    t0 = time.time()
    while True:
        try:
            link = fb.Link()
        except fb.SessionLost as e:
            if time.time() - t0 < 900: time.sleep(2); continue
            say(f"NO_DEVICE: {e}"); return 20
        try:
            fb.enter_firehose(link); fb.configure(link)
            diagnose(link) if mode == "diagnose" else apply(link, mode == "undo"); return 0
        except fb.SessionLost as e:
            say(f"SESSION_LOST: {e}  -> saet OTTO i EDL igen og koer samme kommando igen (den fortsaetter sikkert)"); return 21
        finally:
            link.close()

if __name__ == "__main__":
    mode = (sys.argv[1:] or [""])[0]
    if mode not in ("diagnose", "setslot-b", "undo"):
        print("brug: py otto_rescue.py diagnose | setslot-b | undo"); sys.exit(2)
    try: sys.exit(main(mode))
    except KeyboardInterrupt: say("Stoppet (Ctrl-C). Koer samme kommando igen for at fortsaette."); sys.exit(130)
# END otto_rescue.py
