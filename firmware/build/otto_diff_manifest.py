#!/usr/bin/env python3
"""Port 2: every file that differs between two ext4 images (content, mode, owner, SELinux label).
Usage: otto_diff_manifest.py <old.img> <new.img> <label> <report>
Each image is unpacked (debugfs rdump) one at a time to keep the disk use low; metadata comes from debugfs stat/ea_get."""
import hashlib, os, re, shutil, subprocess, sys, tempfile

ENV = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}


def manifest(img, work):
    d = tempfile.mkdtemp(prefix="rd_", dir=work)
    subprocess.run(["debugfs", "-R", f"rdump / {d}", img], env=ENV, capture_output=True)
    files = {}
    for root, dirs, names in os.walk(d):
        for n in names + dirs:
            p = os.path.join(root, n)
            rel = "/" + os.path.relpath(p, d)
            if os.path.islink(p):
                files[rel] = "link:" + os.readlink(p)
            elif os.path.isfile(p):
                h = hashlib.sha256()
                with open(p, "rb") as f:
                    for b in iter(lambda: f.read(1 << 20), b""):
                        h.update(b)
                files[rel] = h.hexdigest()
            else:
                files[rel] = "dir"
    shutil.rmtree(d)
    # metadata in one debugfs batch
    cmds = []
    paths = sorted(files)
    for p in paths:
        cmds += [f'stat "{p}"', f'ea_get "{p}" security.selinux']
    with tempfile.NamedTemporaryFile("w", delete=False, dir=work) as t:
        t.write("\n".join(cmds) + "\n")
    out = subprocess.run(["debugfs", "-f", t.name, img], env=ENV, capture_output=True, text=True).stdout
    os.unlink(t.name)
    meta, cur = {}, None
    for line in out.splitlines():
        m = re.match(r'debugfs: stat "(.*)"', line)
        if m:
            cur = m.group(1); meta[cur] = ["", "", ""]; continue
        if cur is None:
            continue
        m = re.search(r"Mode:\s+(\d+)", line)
        if m: meta[cur][0] = m.group(1)
        m = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)", line)
        if m: meta[cur][1] = f"{m.group(1)}:{m.group(2)}"
        m = re.search(r'security\.selinux \(\d+\) = "([^"\\]*)', line)
        if m: meta[cur][2] = m.group(1)
    return {p: (files[p],) + tuple(meta.get(p, ["", "", ""])) for p in paths}


def main():
    old, new, label, report = sys.argv[1:5]
    work = os.path.dirname(os.path.abspath(new))
    a = manifest(old, work)
    b = manifest(new, work)
    rows = []
    for p in sorted(set(a) | set(b)):
        if p not in b:
            rows.append(f"REMOVED  {p}")
        elif p not in a:
            rows.append(f"ADDED    {p}  mode={b[p][1]} owner={b[p][2]} label={b[p][3]}")
        elif a[p] != b[p]:
            what = [n for n, i in (("content", 0), ("mode", 1), ("owner", 2), ("label", 3)) if a[p][i] != b[p][i]]
            rows.append(f"CHANGED  {p}  [{','.join(what)}]")
    with open(report, "a") as o:
        o.write(f"===== {label}: {len(a)} -> {len(b)} entries, {len(rows)} differences\n")
        o.write("\n".join(rows) + "\n\n")
    print(f"{label}: {len(rows)} differences")


if __name__ == "__main__":
    main()
