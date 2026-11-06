#!/usr/bin/env python3
"""OTTO A17 — first OTTO OTA (full, Virtual A/B): every A/B partition, signed with the OTTO OTA key.

Inputs
  * dynamic partitions: the FINAL build's images (work/*_b.final.img, sha-checked against
    OTTO_A17_FINAL/SHA256SUMS.txt = what is flashed) + the OTA1 changes written on top with the same
    debugfs helpers as otto_final_build.py (content, mode, owner and label read back and compared);
  * the other 27 partitions: read from OTTO's slot _b on 25-10-2026 (OTA_BASE_B_20261025, sha-verified
    against the device), Magisk-patched init_boot included so root survives.
Payload: avbroot 3.37.1 `payload pack` (signature-verified release) — computes the operations, hashes,
VABC CoW estimates and signs with ~/OTTO/keys/ota/otto_ota.key (its cert is in the image's otacerts.zip).
Nothing leaves the phone.   Usage: python3 otto_ota_build.py <version, e.g. 1>
"""
import hashlib, os, shutil, subprocess, sys, tempfile, time, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import otto_final_build as fb   # apply / verify_written / fsck / sha / run (same rules as the flash build)

VER = sys.argv[1] if len(sys.argv) > 1 else "1"
HOME = fb.HOME
WORK = f"{HOME}/otto_final_build/work"
BASEB = f"{HOME}/OTTO/OTA_BASE_B_20261025"
KEY = f"{HOME}/OTTO/keys/ota/otto_ota.key"
AVB = f"{HOME}/OTTO/TOOLS/avbroot-3.37.1/avbroot"
OW = f"{HOME}/otto_final_build/ota{VER}"
OUT = f"/storage/emulated/0/Download/qfil/otto/OTTO_A17_OTA{VER}"
FLASHED = "/storage/emulated/0/Download/qfil/otto/OTTO_A17_FINAL/SHA256SUMS.txt"
DYN = ["odm", "system", "system_dlkm", "vendor", "vendor_dlkm"]
GROUP, GROUP_MAX = "qti_dynamic_partitions", 6438256640
# Not in the payload: update_engine may not open them (SELinux vendor_mdtp_device / vendor_custom_ab_block_device:
# "Error opening mdtp_a: Permission denied", OTA1 test 25-10-2026), Ottocast's own OTA leaves them out too, and
# they are byte-identical in _a and _b on OTTO (checked 25-10-2026).
SKIP = {"cmnlib", "cmnlib64", "mdtp", "mdtpsecapp", "multiimgoem"}

# What OTA1 changes in system (everything else is byte-identical to the flashed FINAL build)
SYSTEM_CHANGES = [
    (f"{fb.APKS}/v10-connectfront/app/build/outputs/apk/stable/release/app-stable-release.apk",
     "/system/app/OttoLauncher/OttoLauncher.apk", 0o644, 0, 0, fb.SYS),             # launcher v10
    (f"{fb.GEN}/navi/otto_navi.sh", "/system/etc/otto/navi/otto_navi.sh", 0o755, 0, 0, fb.SYS),  # NAVI 0.7
    (f"{fb.FB}/otto_firstboot.sh", "/system/bin/otto_firstboot.sh", 0o755, 0, fb.SH, fb.SYS),    # 25-10 additions
]


def main():
    os.makedirs(f"{OW}/images", exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    stage = tempfile.mkdtemp(prefix="stage_", dir=OW)
    log = open(f"{OUT}/BUILD_LOG.txt", "w")
    note = lambda m: (fb.say(m), log.write(m + "\n"), log.flush())
    note(f"== OTTO A17 OTA{VER}  {time.strftime('%F %T')}")

    flashed = {l.split()[1]: l.split()[0] for l in open(FLASHED) if l.strip().endswith(".final.img")}
    for p in DYN:
        src, dst = f"{WORK}/{p}_b.final.img", f"{OW}/images/{p}.img"
        if fb.sha(src) != flashed[f"{p}_b.final.img"]:
            sys.exit(f"FAILED: {src} is not the flashed FINAL image")
        shutil.copyfile(src, dst)
        note(f"  base {p}: FINAL {flashed[p + '_b.final.img'][:16]}")

    note("== system")
    img = f"{OW}/images/system.img"
    fb.apply(img, SYSTEM_CHANGES, stage)
    fb.verify_written(img, SYSTEM_CHANGES, stage)
    for src, path, *_ in SYSTEM_CHANGES:
        note(f"  {path}  <- {fb.sha(src)[:16]}")
    note(f"  e2fsck: {fb.fsck(img)}")

    # avbroot builds the care map from each dynamic image's AVB hashtree footer. odm and the dlkm images
    # have one; system lost it when the FINAL build grew it, Ottocast's vendor never had one. A fresh
    # unsigned hashtree footer (no FEC) is all that is needed: verity is off on OTTO (vbmeta flags), so
    # boot never checks it.
    note("== AVB hashtree footers")
    for p in DYN:
        img = f"{OW}/images/{p}.img"
        if "Given image does not look like a vbmeta image" not in subprocess.run(
                ["avbtool", "info_image", "--image", img], capture_output=True, text=True).stderr:
            continue
        before = os.path.getsize(img)
        # this avbtool has no --dynamic_partition_size: grow the partition size in 1 MiB steps until
        # --calc_max_image_size says the image fits next to its hashtree + footer
        ht = ["--do_not_generate_fec", "--hash_algorithm", "sha256"]
        ps = before + before // 100 // 1048576 * 1048576 + 1048576
        while int(fb.run(["avbtool", "add_hashtree_footer", "--partition_size", str(ps),
                          "--calc_max_image_size"] + ht).strip()) < before:
            ps += 1048576
        fb.run(["avbtool", "add_hashtree_footer", "--image", img, "--partition_name", p,
                "--partition_size", str(ps)] + ht)
        note(f"  {p}: footer added, {before} -> {os.path.getsize(img)} B")

    note("== firmware/boot partitions (slot _b of OTTO, 25-10-2026)")
    want = {l.split()[1]: l.split()[2] for l in open(f"{BASEB}/SHA256_VERIFY.txt") if l.startswith("OK")}
    fw = []
    for pb, h in sorted(want.items()):
        name = pb[:-2]
        if name in SKIP:
            continue
        src = f"{BASEB}/{pb}.img"
        if fb.sha(src) != h:
            sys.exit(f"FAILED: {src} differs from the device dump")
        os.link(src, f"{OW}/images/{name}.img") if not os.path.exists(f"{OW}/images/{name}.img") else None
        fw.append(name)
    if len(fw) != 27 - len(SKIP):
        sys.exit(f"FAILED: {len(fw)} firmware partitions, expected {27 - len(SKIP)}")
    note(f"  {len(fw)} partitions: {' '.join(fw)}")

    note("== payload")
    ts = int(time.time())
    parts = fw + DYN
    with open(f"{OW}/payload.toml", "w") as t:
        t.write(f"version = 2\n\n[manifest]\nblock_size = 4096\nminor_version = 0\nmax_timestamp = {ts}\n")
        for p in parts:
            t.write(f'\n[[manifest.partitions]]\npartition_name = "{p}"\n')
        t.write("\n[manifest.dynamic_partition_metadata]\nsnapshot_enabled = true\nvabc_enabled = true\n"
                'vabc_compression_param = "lz4"\ncow_version = 2\n'
                f'\n[[manifest.dynamic_partition_metadata.groups]]\nname = "{GROUP}"\nsize = {GROUP_MAX}\n'
                "partition_names = [" + ", ".join(f'"{p}"' for p in DYN) + "]\n")
    total = sum(os.path.getsize(f"{OW}/images/{p}.img") for p in DYN)
    if total > GROUP_MAX:
        sys.exit(f"FAILED: dynamic partitions {total} > group {GROUP_MAX}")
    note(f"  {len(parts)} partitions, dynamic {total} B of {GROUP_MAX}; max_timestamp {ts}")
    pay, props = f"{OW}/payload.bin", f"{OW}/payload_properties.txt"
    fb.run([AVB, "payload", "pack", "-q", "--input-info", f"{OW}/payload.toml", "--input-images",
            f"{OW}/images", "-k", KEY, "-o", pay, "-O", props])
    info = fb.run([AVB, "payload", "info", "-i", pay])
    open(f"{OUT}/payload_info.txt", "w").write(info)
    note(f"  payload {os.path.getsize(pay)} B  sha {fb.sha(pay)[:16]}")

    note("== zip")
    z = f"{OUT}/otto_ota_{VER}.zip"
    meta = (f"ota-type=AB\npost-build=otto/a17/ota{VER}\npost-timestamp={ts}\npre-device=bengal_515\n"
            f"otto-ota={VER}\n")
    with zipfile.ZipFile(z, "w") as zf:
        zf.writestr("META-INF/com/android/metadata", meta, compress_type=zipfile.ZIP_STORED)
        zf.write(props, "payload_properties.txt", compress_type=zipfile.ZIP_STORED)
        zf.write(pay, "payload.bin", compress_type=zipfile.ZIP_STORED)
    zsha = fb.sha(z)
    open(f"{OUT}/SHA256SUMS.txt", "w").write(f"{zsha}  otto_ota_{VER}.zip\n")
    note(f"  {z}  {os.path.getsize(z)} B  sha {zsha}")
    shutil.rmtree(stage)
    note("== DONE")


if __name__ == "__main__":
    main()
