#!/usr/bin/env python3
"""OTTO A17 FINAL2 build (2026-10-25): the flashed FINAL super + what OTA1 was meant to bring, flashed via EDL.

No more OTA (OTA1 bricked slot _a on 25-10-2026): changes go on as a new super for slot _b only.
Input  : the FINAL build's images (work/*_b.final.img, sha-checked against OTTO_A17_FINAL/SHA256SUMS.txt).
Changes: system_b only — launcher v10, NAVI 0.7, otto_firstboot.sh of 25-10; the OTA client removed.
         odm/system_dlkm/vendor/vendor_dlkm go in byte-identical to FINAL.
Output : OTTO_A17_FINAL2_super.simg (+ checksums, lpdump, CHANGED_FILES.txt).  Same lpmake layout as FINAL.
Usage  : python3 otto_final2_build.py
"""
import os, shutil, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import otto_final_build as fb   # apply / verify_written / fsck / sha / run (same rules as the FINAL build)

WORK = f"{fb.HOME}/otto_final_build/work"
W2 = f"{fb.HOME}/otto_final_build/final2"
OUT = "/storage/emulated/0/Download/qfil/otto/OTTO_A17_FINAL2"
FLASHED = "/storage/emulated/0/Download/qfil/otto/OTTO_A17_FINAL/SHA256SUMS.txt"
NAME = "OTTO_A17_FINAL2_super"

SYSTEM_CHANGES = [
    (f"{fb.APKS}/v10-connectfront/app/build/outputs/apk/stable/release/app-stable-release.apk",
     "/system/app/OttoLauncher/OttoLauncher.apk", 0o644, 0, 0, fb.SYS),             # launcher v10
    (f"{fb.GEN}/navi/otto_navi.sh", "/system/etc/otto/navi/otto_navi.sh", 0o755, 0, 0, fb.SYS),  # NAVI 0.7
    (f"{fb.FB}/otto_firstboot.sh", "/system/bin/otto_firstboot.sh", 0o755, 0, fb.SH, fb.SYS),    # 25-10 additions
]
# The OTA client. update_engine itself is part of the GSI and stays; with no client nothing can start an update.
SYSTEM_REMOVE = ["/system/etc/otto/otto_ota.dex"]
# What OTA1 carried (otto/OTTO_A17_OTA1/BUILD_LOG.txt): FINAL2 must bring exactly the same files
OTA1_SHA = {"/system/app/OttoLauncher/OttoLauncher.apk": "d8c6382b95f2b732",
            "/system/etc/otto/navi/otto_navi.sh": "03536c10497378e3",
            "/system/bin/otto_firstboot.sh": "9ffee157f3391f55"}


def main():
    os.makedirs(W2, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    stage = tempfile.mkdtemp(prefix="stage_", dir=W2)
    log = open(f"{OUT}/BUILD_LOG.txt", "w")
    note = lambda m: (fb.say(m), log.write(m + "\n"), log.flush())
    note(f"== OTTO A17 FINAL2 build  {time.strftime('%F %T')}")

    for src, path, *_ in SYSTEM_CHANGES:
        if fb.sha(src)[:16] != OTA1_SHA[path]:
            sys.exit(f"FAILED: {src} is not the file OTA1 carried")
    flashed = {l.split()[1]: l.split()[0] for l in open(FLASHED) if l.strip().endswith(".final.img")}
    imgs = {}
    for p in fb.PARTS:
        src, dst = f"{WORK}/{p}.final.img", f"{W2}/{p}.img"
        if fb.sha(src) != flashed[f"{p}.final.img"]:
            sys.exit(f"FAILED: {src} is not the flashed FINAL image")
        shutil.copyfile(src, dst)
        imgs[p] = dst
        note(f"  base {p}: FINAL {flashed[p + '.final.img'][:16]}")

    note("== system_b")
    img = imgs["system_b"]
    fb.apply(img, SYSTEM_CHANGES, stage, SYSTEM_REMOVE)
    fb.verify_written(img, SYSTEM_CHANGES, stage, SYSTEM_REMOVE)
    for src, path, *_ in SYSTEM_CHANGES:
        note(f"  {path}  <- {fb.sha(src)[:16]}")
    for r in SYSTEM_REMOVE:
        note(f"  removed {r}")
    note(f"  e2fsck: {fb.fsck(img)}")
    for p in fb.PARTS:
        if p != "system_b" and fb.sha(imgs[p]) != flashed[f"{p}.final.img"]:
            sys.exit(f"FAILED: {p} changed")
    note("  odm/system_dlkm/vendor/vendor_dlkm: byte-identical to FINAL")

    note("== super")
    raw = f"{W2}/{NAME}.raw"
    args = ["lpmake", "--metadata-size", "65536", "--super-name", "super", "--metadata-slots", "3",
            "--device", f"super:{fb.SUPER_SIZE}", "--group", f"{fb.GROUP}:{fb.GROUP_MAX}", "--virtual-ab",
            "--output", raw]
    total = 0
    for p in fb.PARTS:
        s = os.path.getsize(imgs[p])
        total += s
        args += ["--partition", f"{p}:readonly:{s}:{fb.GROUP}", "--image", f"{p}={imgs[p]}"]
    if total > fb.GROUP_MAX:
        sys.exit(f"FAILED: partitions {total} > group {fb.GROUP_MAX}")
    fb.run(args)
    note(f"  partitions {total} B of {fb.GROUP_MAX} (free {fb.GROUP_MAX - total})")
    open(f"{OUT}/{NAME}.lpdump.txt", "w").write(fb.run(["lpdump", raw]))
    up = tempfile.mkdtemp(prefix="unpack_", dir=W2)
    fb.run(["lpunpack", raw, up])
    for p in fb.PARTS:
        if fb.sha(f"{up}/{p}.img") != fb.sha(imgs[p]):
            sys.exit(f"FAILED: unpacked {p} differs")
    shutil.rmtree(up)
    note("  lpunpack: all partitions byte-identical to the inputs")
    rsha = fb.sha(raw)
    note(f"  raw  {rsha}")
    simg = f"{OUT}/{NAME}.simg"
    fb.run(["img2simg", raw, simg])
    ssha = fb.sha(simg)
    note(f"  simg {ssha}")
    with open(f"{OUT}/SHA256SUMS.txt", "w") as o:
        o.write(f"{ssha}  {NAME}.simg\n{rsha}  {NAME}.raw (expanded content, {fb.SUPER_SIZE} B)\n")
        for p in fb.PARTS:
            o.write(f"{fb.sha(imgs[p])}  {p}.final2.img\n")

    note("== changed files system_b FINAL -> FINAL2")
    fb.run([sys.executable, f"{os.path.dirname(os.path.abspath(__file__))}/otto_diff_manifest.py",
            f"{WORK}/system_b.final.img", img, "system_b", f"{OUT}/CHANGED_FILES.txt"])
    note("  " + open(f"{OUT}/CHANGED_FILES.txt").read().strip().replace("\n", "\n  "))
    os.unlink(raw)
    shutil.rmtree(stage)
    note("== DONE")


if __name__ == "__main__":
    main()
