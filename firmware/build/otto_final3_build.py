#!/usr/bin/env python3
"""OTTO A17 FINAL3 build (2026-11-01): the running FINAL2 super + the owner-approved final list, flashed via EDL.

No OTA (golden rule): changes go on as a new super for slot _b only, built exactly like FINAL2.
Base   : FINAL2's own super (OTTO_A17_FINAL2/OTTO_A17_FINAL2_super.simg) -> simg2img -> lpunpack; every partition is
         sha-checked against OTTO_A17_FINAL2/SHA256SUMS.txt before use.
Changes: system_b only; each input is sha-guarded (the exact file tested live on OTTO, 2026-10-31/11-01):
         R8 recorder (High profile, 25 ms synth deadline, early scrcpy retries, QP 25-40), lylinkservice and
         lyscrservice without reboot() (F10/F10b), otto_cargps F6/F7, run.sh in parallel (F4), VDS confirm (F3),
         GPU/SF placement (F14), atfwd stop (F13, new .rc), otto_firstboot (F23, Wi-Fi wait, 12 Mbit/s default),
         launcher v18 and OTTO Spotify 1.2. Rebuild 2026-11-01 (owner): + launcher v18 (boot handover, quick
         Tilbage/Hjem, album art over https), otto_cargps with satellites=12 extras (fixes "Searching for GPS"). F11 is NOT included (owner, 2026-11-01): FINAL2's ly_link.sh stays.
         odm/system_dlkm/vendor/vendor_dlkm go in byte-identical to FINAL2.
Output : OTTO_A17_FINAL3/OTTO_A17_FINAL3_super.simg (+ SHA256SUMS, lpdump, BUILD_LOG, CHANGED_FILES). Same lpmake
         layout as FINAL/FINAL2.
Usage  : python3 otto_final3_build.py
"""
import os, shutil, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import otto_final_build as fb   # apply / verify_written / fsck / sha / run (same rules as the FINAL build)

W3 = f"{fb.HOME}/otto_final_build/final3"
F2 = "/storage/emulated/0/Download/qfil/otto/OTTO_A17_FINAL2"
OUT = "/storage/emulated/0/Download/qfil/otto/OTTO_A17_FINAL3"
NAME = "OTTO_A17_FINAL3_super"
PREP = "/storage/emulated/0/Download/OTTO_A17_ULTIMATE_FINAL_PREP_20261031"
V15 = "/storage/emulated/0/Download/OTTO_FEMTO_V15_41296667082"   # OTTO Spotify 1.2
V18 = "/storage/emulated/0/Download/OTTO_FEMTO_V18_41316851542"   # launcher v18

# (source, image path, mode, uid, gid, label, sha256 prefix of the file tested live)
SYSTEM_CHANGES = [
    (f"{PREP}/recorder8/libscreenrecord_r8.so", "/system/lib/libscreenrecord.so", 0o644, 0, 0, fb.SYS, "fa8c668f0daf13dd"),
    (f"{PREP}/lylink_noreboot/lylinkservice.patched", "/system/bin/lylinkservice", 0o755, 0, fb.SH, fb.SYS, "9b3b76b5f5cf9240"),
    (f"{PREP}/lylink_noreboot/lyscrservice.patched", "/system/bin/lyscrservice", 0o755, 0, fb.SH, fb.SYS, "8c727747e1457169"),
    (f"{PREP}/gps_final/out/otto_cargps_final.jar", "/system/etc/otto/navi/bin/otto_cargps.jar", 0o644, 0, 0, fb.SYS, "84d5e59256fadb5e"),
    (f"{PREP}/boot_final/run.sh", "/system/etc/otto/boot/run.sh", 0o755, 0, 0, fb.SYS, "5e105e9ae282a5f3"),
    (f"{PREP}/boot_final/service.d/24-otto-a3a-gpu465.sh", "/system/etc/otto/boot/service.d/24-otto-a3a-gpu465.sh",
     0o755, 0, 0, fb.SYS, "df1a1c3f5fadc637"),
    (f"{PREP}/boot_final/service.d/25-otto-hwc-vds-confirm.sh", "/system/etc/otto/boot/service.d/25-otto-hwc-vds-confirm.sh",
     0o755, 0, 0, fb.SYS, "0dbd04128b269043"),
    (f"{PREP}/boot_final/init/otto_final_f13.rc", "/system/etc/init/otto_final_f13.rc", 0o644, 0, 0, fb.SYS, "8cdea022a263ee6f"),
    (f"{PREP}/boot_final/system_bin/otto_firstboot.sh", "/system/bin/otto_firstboot.sh", 0o755, 0, fb.SH, fb.SYS, "4fa8184307784705"),
    (f"{V18}/app/build/outputs/apk/stable/release/app-stable-release.apk", "/system/app/OttoLauncher/OttoLauncher.apk",
     0o644, 0, 0, fb.SYS, "9410947491de64cb"),
    (f"{V15}/spotify/spotify/build/outputs/apk/release/spotify-release.apk", "/system/app/OttoSpotify/OttoSpotify.apk",
     0o644, 0, 0, fb.SYS, "2ac2d47b1a23a1c2"),
]


def main():
    os.makedirs(W3, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    log = open(f"{OUT}/BUILD_LOG.txt", "w")
    note = lambda m: (fb.say(m), log.write(m + "\n"), log.flush())
    note(f"== OTTO A17 FINAL3 build  {time.strftime('%F %T')}")

    for src, path, *_, want in SYSTEM_CHANGES:
        if not os.path.isfile(src) or fb.sha(src)[:16] != want:
            sys.exit(f"FAILED: {src} is not the file tested live ({want})")
    changes = [c[:6] for c in SYSTEM_CHANGES]

    # Base: FINAL2's own super, unpacked and checked partition by partition.
    sums = {}
    for l in open(f"{F2}/SHA256SUMS.txt"):
        parts = l.split()
        if len(parts) >= 2:
            sums[parts[1]] = parts[0]
    simg = f"{F2}/OTTO_A17_FINAL2_super.simg"
    if fb.sha(simg) != sums["OTTO_A17_FINAL2_super.simg"]:
        sys.exit("FAILED: FINAL2 simg does not match its SHA256SUMS")
    base = f"{W3}/base"
    os.makedirs(base, exist_ok=True)
    raw2 = f"{W3}/final2.raw"
    fb.run(["simg2img", simg, raw2])
    if fb.sha(raw2) != sums["OTTO_A17_FINAL2_super.raw"]:
        sys.exit("FAILED: expanded FINAL2 super does not match")
    fb.run(["lpunpack", raw2, base])
    os.unlink(raw2)
    imgs = {}
    for p in fb.PARTS:
        src = f"{base}/{p}.img"
        if fb.sha(src) != sums[f"{p}.final2.img"]:
            sys.exit(f"FAILED: unpacked {p} is not FINAL2's")
        imgs[p] = src
        note(f"  base {p}: FINAL2 {sums[p + '.final2.img'][:16]}")
    sysimg = f"{W3}/system_b.final3.img"
    shutil.copyfile(imgs["system_b"], sysimg)
    final2_system = imgs["system_b"]
    imgs["system_b"] = sysimg

    note("== system_b")
    stage = tempfile.mkdtemp(prefix="stage_", dir=W3)
    fb.apply(sysimg, changes, stage)
    fb.verify_written(sysimg, changes, stage)
    for src, path, *_ in changes:
        note(f"  {path}  <- {fb.sha(src)[:16]}")
    note(f"  e2fsck: {fb.fsck(sysimg)}")
    for p in fb.PARTS:
        if p != "system_b" and fb.sha(imgs[p]) != sums[f"{p}.final2.img"]:
            sys.exit(f"FAILED: {p} changed")
    note("  odm/system_dlkm/vendor/vendor_dlkm: byte-identical to FINAL2")

    note("== super")
    raw = f"{W3}/{NAME}.raw"
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
    up = tempfile.mkdtemp(prefix="unpack_", dir=W3)
    fb.run(["lpunpack", raw, up])
    for p in fb.PARTS:
        if fb.sha(f"{up}/{p}.img") != fb.sha(imgs[p]):
            sys.exit(f"FAILED: unpacked {p} differs")
    shutil.rmtree(up)
    note("  lpunpack: all partitions byte-identical to the inputs")
    rsha = fb.sha(raw)
    note(f"  raw  {rsha}")
    out_simg = f"{OUT}/{NAME}.simg"
    fb.run(["img2simg", raw, out_simg])
    ssha = fb.sha(out_simg)
    note(f"  simg {ssha}")
    with open(f"{OUT}/SHA256SUMS.txt", "w") as o:
        o.write(f"{ssha}  {NAME}.simg\n{rsha}  {NAME}.raw (expanded content, {fb.SUPER_SIZE} B)\n")
        for p in fb.PARTS:
            o.write(f"{fb.sha(imgs[p])}  {p}.final3.img\n")

    note("== changed files system_b FINAL2 -> FINAL3")
    fb.run([sys.executable, f"{os.path.dirname(os.path.abspath(__file__))}/otto_diff_manifest.py",
            final2_system, sysimg, "system_b", f"{OUT}/CHANGED_FILES.txt"])
    note("  " + open(f"{OUT}/CHANGED_FILES.txt").read().strip().replace("\n", "\n  "))
    os.unlink(raw)
    shutil.rmtree(stage)
    note("== DONE")


if __name__ == "__main__":
    main()
