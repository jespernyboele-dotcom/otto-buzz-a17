#!/usr/bin/env python3
"""OTTO A17 FINAL build (2026-10-24): today's proven super + the approved change list, nothing else.

Input  : the base partition images of the running OTTO (super_parts/*.img; system_b/vendor_b proven
         byte-identical to OTTO's partitions, and lpmake of them reproduces today's super exactly) and
         vendor_b.unshared.img (vendor_b with shared_blocks removed by e2fsck -E unshare_blocks; the two
         files e2fsck damaged were restored from the original and all 2824 files verified identical).
Output : OTTO_A17_FINAL_super.simg (+ .raw, checksums, lpdump, change manifest).
Method : debugfs writes each file with the exact mode, owner and SELinux label the image already uses;
         system_b is grown first (super group has the room). Every step is checked; the first error stops.
Usage  : python3 otto_final_build.py [--keep-raw]
"""
import hashlib, os, re, shutil, subprocess, sys, tempfile, zipfile

HOME = "/data/data/com.termux/files/home"
BASE = f"{HOME}/otto_mig_work/super_parts"
WORK = f"{HOME}/otto_final_build/work"
FB = "/storage/emulated/0/Download/qfil/otto/final_build"
GEN = f"{FB}/build/gen"
INP = f"{HOME}/otto_final_build/inputs"
APKS = "/storage/emulated/0/Download/qfil/otto/release_apks"
OUT = "/storage/emulated/0/Download/qfil/otto/OTTO_A17_FINAL"
GROW_SYSTEM = 512 * 1024 * 1024
SUPER_SIZE, GROUP, GROUP_MAX = 6442450944, "qti_dynamic_partitions_b", 6438256640
PARTS = ["odm_b", "system_b", "system_dlkm_b", "vendor_b", "vendor_dlkm_b"]
ENV = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}

SYS, SH, VND, VCF = "u:object_r:system_file:s0", 2000, "u:object_r:vendor_file:s0", "u:object_r:vendor_configs_file:s0"
MOD = f"{INP}/mod/modules"
APP = f"{INP}/apk"


def run(cmd, **kw):
    r = subprocess.run(cmd, env=ENV, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit(f"FAILED ({r.returncode}): {' '.join(cmd)}\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    return r.stdout


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def say(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- what goes in (approved list, 2026-10-24)
def system_changes(stage):
    """(source, image path, mode, uid, gid, label); a None source makes a directory."""
    libs = {}
    for pkg, name in (("org.adaway", "AdAway"), ("helium314.keyboard", "HeliBoard")):
        # extractNativeLibs=true + deflated .so: a system app needs them unpacked next to the APK
        d = f"{stage}/{name}_lib"
        os.makedirs(d, exist_ok=True)
        with zipfile.ZipFile(f"{APP}/{pkg}/base.apk") as z:
            libs[name] = []
            for n in z.namelist():
                if n.startswith("lib/arm64-v8a/") and n.endswith(".so"):
                    p = f"{d}/{os.path.basename(n)}"
                    with open(p, "wb") as o:
                        o.write(z.read(n))
                    libs[name].append(p)
    c = []
    d = lambda path: c.append((None, path, 0o755, 0, 0, SYS))
    f = lambda src, path, mode=0o644, gid=0: c.append((src, path, mode, 0, gid, SYS))
    # from the Magisk modules
    f(f"{MOD}/hosts/system/etc/hosts", "/system/etc/hosts")
    d("/system/media")
    f(f"{MOD}/otto_bootanim/system/media/bootanimation.zip", "/system/media/bootanimation.zip")
    f(f"{MOD}/otto_usb0_route_ff/system/bin/otto_usb0_route.sh", "/system/bin/otto_usb0_route.sh", 0o755, SH)
    f(f"{FB}/ly_link.sh", "/system/bin/ly_link.sh", 0o755, SH)
    f(f"{FB}/otto_firstboot.sh", "/system/bin/otto_firstboot.sh", 0o755, SH)
    f(f"{APKS}/LYFactoryTools-OTTO-EN.apk", "/system/priv-app/LYFactoryTools/LYFactoryTools.apk")
    for o in ("OttoChrome", "OttoSystemUi", "OttoSafeZone"):
        src = {"OttoChrome": f"{MOD}/otto_test_chrome/system/product/overlay/OttoChrome.apk",
               "OttoSystemUi": f"{MOD}/otto_test_chrome/system/product/overlay/OttoSystemUi.apk",
               "OttoSafeZone": f"{MOD}/otto_test_safezone/system/product/overlay/OttoSafeZone.apk"}[o]
        f(src, f"/system/product/overlay/{o}.apk")
    # NAVI + boot scripts (former Magisk module / post-fs-data.d / service.d)
    for p in ("/system/etc/otto/navi", "/system/etc/otto/navi/bin", "/system/etc/otto/navi/profiles",
              "/system/etc/otto/boot", "/system/etc/otto/boot/post-fs-data.d", "/system/etc/otto/boot/service.d"):
        d(p)
    f(f"{GEN}/navi/start.sh", "/system/etc/otto/navi/start.sh", 0o755)
    f(f"{GEN}/navi/otto_navi.sh", "/system/etc/otto/navi/otto_navi.sh", 0o755)
    f(f"{GEN}/navi/bin/otto_rgid", "/system/etc/otto/navi/bin/otto_rgid", 0o755)
    for j in ("otto_aanav.jar", "otto_cargps.jar"):
        f(f"{GEN}/navi/bin/{j}", f"/system/etc/otto/navi/bin/{j}")
    f(f"{GEN}/navi/profiles/mib4.conf", "/system/etc/otto/navi/profiles/mib4.conf")
    f(f"{GEN}/boot/run.sh", "/system/etc/otto/boot/run.sh", 0o755)
    for sub in ("post-fs-data.d", "service.d"):
        for n in sorted(os.listdir(f"{GEN}/boot/{sub}")):
            f(f"{GEN}/boot/{sub}/{n}", f"/system/etc/otto/boot/{sub}/{n}", 0o755)
    f(f"{GEN}/otto_final_r1.rc", "/system/etc/init/otto_final_r1.rc")
    # SELinux
    c.append((f"{GEN}/plat_sepolicy.cil", "/system/etc/selinux/plat_sepolicy.cil", 0o644, 0, 0, "u:object_r:sepolicy_file:s0"))
    c.append((f"{GEN}/plat_property_contexts", "/system/etc/selinux/plat_property_contexts", 0o644, 0, 0,
              "u:object_r:property_contexts_file:s0"))
    # OTA
    f(f"{FB}/ota/otacerts.zip", "/system/etc/security/otacerts.zip")
    f(f"{FB}/ota/otto_ota.dex", "/system/etc/otto/otto_ota.dex")
    # apps as system apps (/system/app: no privileged permissions, so no privapp whitelist needed)
    apps = [("OttoLauncher", f"{APKS}/v9-frontcheck/app/build/outputs/apk/stable/release/app-stable-release.apk", []),
            ("OttoSpotify", f"{APP}/dk.otto.spotify/base.apk", []),
            ("Breezy", f"{APP}/org.breezyweather/base.apk", []),
            ("AdAway", f"{APP}/org.adaway/base.apk", libs["AdAway"]),
            ("HeliBoard", f"{APP}/helium314.keyboard/base.apk", libs["HeliBoard"]),
            ("AndroidAuto", f"{APP}/com.google.android.projection.gearhead/base.apk", [])]
    for name, apk, so in apps:
        d(f"/system/app/{name}")
        f(apk, f"/system/app/{name}/{name}.apk")
        if name == "AndroidAuto":
            for s in ("split_config.arm64_v8a.apk", "split_config.en.apk", "split_config.xxhdpi.apk"):
                f(f"{APP}/com.google.android.projection.gearhead/{s}", f"/system/app/{name}/{s}")
        if so:
            d(f"/system/app/{name}/lib")
            d(f"/system/app/{name}/lib/arm64")
            for s in so:
                f(s, f"/system/app/{name}/lib/arm64/{os.path.basename(s)}")
    # WebView: the uncompressed full APK instead of .apk.gz + stub (the stub's first-boot unpacking failed before)
    f(f"{APP}/com.google.android.webview/base.apk", "/system/product/app/WebViewGoogle/WebViewGoogle.apk")
    return c


SYSTEM_REMOVE = [
    "/system/etc/bpf/dmabuf/dmabufIter.bpf",            # module otto_bpf_skip_dmabuf (.replace = empty dir)
    "/system/system_ext/priv-app/Launcher3QuickStep",   # decision C
    "/system/product/app/WebViewGoogle-Stub",
    "/system/product/app/WebViewGoogle/WebViewGoogle.apk.gz",
]


def vendor_changes():
    return [(f"{MOD}/otto60hz_test/system/vendor/lib64/libsdmcore.so", "/lib64/libsdmcore.so", 0o644, 0, 0, VND),
            (f"{MOD}/otto_wfdhdcp_seccomp_gettid/system/vendor/etc/seccomp_policy/wfdhdcphalservice.policy",
             "/etc/seccomp_policy/wfdhdcphalservice.policy", 0o644, 0, 0, VCF),
            (f"{GEN}/vendor_sepolicy.cil", "/etc/selinux/vendor_sepolicy.cil", 0o644, 0, 0, VCF)]


# ---------------------------------------------------------------- debugfs helpers
def dfs(img, cmds, write=True):
    with tempfile.NamedTemporaryFile("w", suffix=".dfs", delete=False) as t:
        t.write("\n".join(cmds) + "\n")
    out = run(["debugfs"] + (["-w"] if write else []) + ["-f", t.name, img])
    os.unlink(t.name)
    return out


def exists(img, path):
    r = subprocess.run(["debugfs", "-R", f'stat "{path}"', img], env=ENV, capture_output=True, text=True)
    return "Inode:" in r.stdout


def tree_rm(img, path):
    """rm/rmdir commands for path and everything under it (children first)."""
    if "Type: regular" in run(["debugfs", "-R", f'stat "{path}"', img]):
        return [f'rm "{path}"']
    out = run(["debugfs", "-R", f'ls -p "{path}"', img])
    cmds = []
    for line in out.splitlines():
        parts = line.strip().split("/")
        if len(parts) < 7 or parts[5] in (".", ".."):
            continue
        child = f"{path}/{parts[5]}"
        is_dir = int(parts[2], 8) & 0o170000 == 0o040000     # debugfs prints e.g. 040755 / 100644
        cmds += tree_rm(img, child) if is_dir else [f'rm "{child}"']
    return cmds + [f'rmdir "{path}"']


def apply(img, changes, stage, removes=()):
    labels = {}
    cmds = []
    for r in removes:
        if exists(img, r):
            cmds += tree_rm(img, r)
            say(f"  remove {r}")
        else:
            sys.exit(f"FAILED: {r} not in {img}")
    for src, path, mode, uid, gid, label in changes:
        if label not in labels:
            lf = f"{stage}/label_{len(labels)}.bin"
            with open(lf, "wb") as o:
                o.write(label.encode() + b"\0")        # stored NUL-terminated, like every label in these images
            labels[label] = lf
        if src is None:
            if not exists(img, path):
                cmds.append(f'mkdir "{path}"')
            kind = 0o040000
        else:
            if not os.path.isfile(src):
                sys.exit(f"FAILED: input missing: {src}")
            if exists(img, path):
                cmds.append(f'rm "{path}"')
            cmds.append(f'write "{src}" "{path}"')
            kind = 0o100000
        cmds += [f'sif "{path}" mode 0{kind | mode:o}', f'sif "{path}" uid {uid}', f'sif "{path}" gid {gid}',
                 f'ea_set -f "{labels[label]}" "{path}" security.selinux']
    dfs(img, cmds)


def verify_written(img, changes, stage, removes=()):
    """Read every written file back and compare content, mode, owner and label; removed paths must be gone."""
    bad = []
    for r in removes:
        if exists(img, r):
            bad.append(f"still present: {r}")
    for src, path, mode, uid, gid, label in changes:
        st = run(["debugfs", "-R", f'stat "{path}"', img])
        ea = run(["debugfs", "-R", f'ea_get "{path}" security.selinux', img])
        m = re.search(r"Mode:\s+0?(\d+)", st)
        o = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)", st)
        if not m or int(m.group(1), 8) != mode:
            bad.append(f"mode {path}: {m.group(1) if m else '?'}")
        if not o or (int(o.group(1)), int(o.group(2))) != (uid, gid):
            bad.append(f"owner {path}: {o.groups() if o else '?'}")
        if f'"{label}\\000"' not in ea:
            bad.append(f"label {path}: {ea.strip()[:80]}")
        if src is not None:
            tmp = f"{stage}/readback.bin"
            run(["debugfs", "-R", f'dump "{path}" "{tmp}"', img])
            if sha(tmp) != sha(src):
                bad.append(f"content {path}")
            os.unlink(tmp)
    if bad:
        sys.exit("VERIFY FAILED:\n  " + "\n  ".join(bad))


def grow(img, extra):
    size = os.path.getsize(img) + extra
    os.truncate(img, size)
    run(["resize2fs", img])
    return size


def fsck(img):
    r = subprocess.run(["e2fsck", "-fn", img], env=ENV, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"e2fsck FAILED on {img}:\n{r.stdout[-1500:]}")
    return r.stdout.strip().splitlines()[-1]


def main():
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    stage = tempfile.mkdtemp(prefix="stage_", dir=WORK)
    log = open(f"{OUT}/BUILD_LOG.txt", "w")
    note = lambda m: (say(m), log.write(m + "\n"))

    note("== OTTO A17 FINAL build")
    imgs = {}
    for p in PARTS:
        src = f"{WORK}/vendor_b.unshared.img" if p == "vendor_b" else f"{BASE}/{p}.img"
        dst = f"{WORK}/{p}.final.img"
        shutil.copyfile(src, dst)
        imgs[p] = dst
        note(f"  base {p}: {os.path.basename(src)} sha {sha(src)[:16]}")

    note("== system_b")
    note(f"  grown to {grow(imgs['system_b'], GROW_SYSTEM)} bytes")
    sc = system_changes(stage)
    apply(imgs["system_b"], sc, stage, SYSTEM_REMOVE)
    verify_written(imgs["system_b"], sc, stage, SYSTEM_REMOVE)
    note(f"  {len(sc)} writes + {len(SYSTEM_REMOVE)} removals verified (content, mode, label)")
    note(f"  e2fsck: {fsck(imgs['system_b'])}")

    note("== vendor_b")
    vc = vendor_changes()
    apply(imgs["vendor_b"], vc, stage)
    verify_written(imgs["vendor_b"], vc, stage)
    note(f"  {len(vc)} writes verified; e2fsck: {fsck(imgs['vendor_b'])}")

    note("== super")
    raw = f"{WORK}/OTTO_A17_FINAL_super.raw"
    args = ["lpmake", "--metadata-size", "65536", "--super-name", "super", "--metadata-slots", "3",
            "--device", f"super:{SUPER_SIZE}", "--group", f"{GROUP}:{GROUP_MAX}", "--virtual-ab", "--output", raw]
    total = 0
    for p in PARTS:
        s = os.path.getsize(imgs[p])
        total += s
        args += ["--partition", f"{p}:readonly:{s}:{GROUP}", "--image", f"{p}={imgs[p]}"]
    if total > GROUP_MAX:
        sys.exit(f"FAILED: partitions {total} > group {GROUP_MAX}")
    run(args)
    note(f"  partitions {total} B of {GROUP_MAX} (free {GROUP_MAX - total})")
    open(f"{OUT}/OTTO_A17_FINAL_super.lpdump.txt", "w").write(run(["lpdump", raw]))
    rsha = sha(raw)
    note(f"  raw  {rsha}")
    # unpack again: every partition must come out byte-identical to what went in
    up = tempfile.mkdtemp(prefix="unpack_", dir=WORK)
    run(["lpunpack", raw, up])
    for p in PARTS:
        if sha(f"{up}/{p}.img") != sha(imgs[p]):
            sys.exit(f"FAILED: unpacked {p} differs")
    shutil.rmtree(up)
    note("  lpunpack: all partitions byte-identical to the inputs")
    simg = f"{OUT}/OTTO_A17_FINAL_super.simg"
    run(["img2simg", raw, simg])
    ssha = sha(simg)
    note(f"  simg {ssha}")
    with open(f"{OUT}/SHA256SUMS.txt", "w") as o:
        o.write(f"{ssha}  OTTO_A17_FINAL_super.simg\n{rsha}  OTTO_A17_FINAL_super.raw (expanded content, {SUPER_SIZE} B)\n")
        for p in PARTS:
            o.write(f"{sha(imgs[p])}  {p}.final.img\n")
    if "--keep-raw" not in sys.argv:
        os.unlink(raw)
    shutil.rmtree(stage)
    note("== DONE")


if __name__ == "__main__":
    main()
