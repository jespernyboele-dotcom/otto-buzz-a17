#!/usr/bin/env python3
"""Compare two ext4 images file-by-file via debugfs (no mount, no extraction).
Compares: type, mode, uid, gid, size, content sha256 (regular files), symlink target, all xattrs.
Usage: compare_ext4_trees.py <imageA> <imageB> <report.tsv>   (exit 0 = report written)"""
import hashlib, re, subprocess, sys

def dfs(img, cmd):
    return subprocess.run(["debugfs", "-R", cmd, img], capture_output=True).stdout

def walk(img):
    out, todo = {}, ["/"]
    while todo:
        d = todo.pop()
        for line in dfs(img, f'ls -p "{d}"').decode("utf-8", "replace").splitlines():
            f = line.strip().split("/")
            if len(f) < 7: continue
            ino, mode, uid, gid, name, size = f[1], f[2], f[3], f[4], f[5], f[6]
            if name in (".", ".."): continue
            p = (d.rstrip("/") + "/" + name) if d != "/" else "/" + name
            out[p] = {"mode": mode, "uid": uid, "gid": gid, "size": size}
            if mode.startswith("04"): todo.append(p)
    return out

def detail(img, p, e):
    m = e["mode"]
    if m.lstrip("0").startswith("10"):
        e["sha"] = hashlib.sha256(dfs(img, f'cat "{p}"')).hexdigest()
    elif m.lstrip("0").startswith("12"):
        st = dfs(img, f'stat "{p}"').decode("utf-8", "replace")
        mm = re.search(r'Fast link dest: "(.*)"', st)
        e["link"] = mm.group(1) if mm else hashlib.sha256(dfs(img, f'cat "{p}"')).hexdigest()
    e["xattr"] = " | ".join(sorted(l.strip() for l in dfs(img, f'ea_list "{p}"').decode("utf-8", "replace").splitlines() if l.strip()))

a_img, b_img, rep = sys.argv[1:4]
A, B = walk(a_img), walk(b_img)
rows, same = [], 0
for p in sorted(set(A) | set(B)):
    if p not in A: rows.append(("ONLY_IN_B", p, "")); detail(b_img, p, B[p]); continue
    if p not in B: rows.append(("ONLY_IN_A", p, "")); continue
    detail(a_img, p, A[p]); detail(b_img, p, B[p])
    diffs = [k for k in ("mode", "uid", "gid", "size", "sha", "link", "xattr") if A[p].get(k) != B[p].get(k)]
    if diffs: rows.append(("DIFF", p, ",".join(diffs)))
    else: same += 1
with open(rep, "w") as f:
    f.write(f"# A={a_img}\n# B={b_img}\n# entries A={len(A)} B={len(B)} identical={same} differing={len(rows)}\n")
    for r in rows: f.write("\t".join(r) + "\n")
print(f"entries A={len(A)} B={len(B)} identical={same} differing={len(rows)}")
for r in rows: print("\t".join(r))
