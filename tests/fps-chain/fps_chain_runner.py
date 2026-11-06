#!/usr/bin/env python3
"""OTTOBUZZ unattended FPS baseline runner (host side: Pixel / Termux / Debian).

Two modes, each behind its own gate:
  discover  GATE A, read-only. getprop/cat/dumpsys/ss/sha256sum/mountinfo; saves everything on the host.
  run       GATE B, requires --approve-gate-b. In addition to the read-only sampling it performs exactly these
            state-changing but reversible actions on OTTO, each logged as ACTION:
              1. pm grant READ_MEDIA_VIDEO to the player, adb push of the clips to DEV_DIR
              2. am start -S (VIEW, video/mp4) of each clip on display 0 (shown on the MIB4 via CarPlay);
                 -S stops only the installed test player before each clip
              3. input keyevent HOME at the end (back to the launcher, which is the normal home screen)
              4. rm -r DEV_DIR, pm revoke READ_MEDIA_VIDEO
            Never: reboot, setprop, remount, install, force-stop, service restart, SurfaceFlinger stat reset.

Usage:  python3 -I 03_RUNNER.py --otto <ip> discover
        python3 -I 03_RUNNER.py --otto <ip> run --approve-gate-b [--player pkg/.Activity] [--with-24]
"""
import argparse, base64, collections, csv, hashlib, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ADB = "/data/data/com.termux/files/usr/bin/adb"
PORT = 29527
PLAYER = "com.brouken.player/.PlayerActivity"          # Just (Video) Player 0.217, F-Droid, installed 2026-10-31
# Run 06:29 showed EACCES on a shell-created Android/data folder, so the clips go to shared Movies/ and the player gets
# READ_MEDIA_VIDEO for the run only (revoked at the end; it was not granted before).
DEV_DIR = "/sdcard/Movies/otto_fps_test"
R3_SHAS = {"6b38d2dfe5c6ff63a350f6c79d2c826fe5af6e4d1eb866e2239331932c2903c0": "R3",
           "26647c860c463c4275af9466323017a5d4336d362de3b3078de7bfad675840a0": "R4-cadence25",
           "996319800b14a2ff453cf635a27b041e728bf47552d05a2053f756bca5729ece": "R5-source",
           "a6be9a5a504d3060bd24b7ee79c2cfb7297bc02ad54b1f2422d02764cecfae2c": "R6-source",
           "c63503134f0dc408e37ff49b2f29465dea27542d212b891f30245d389654f8d3": "R7-high",
           "fa8c668f0daf13dd8ceaa9c2e6f2465943ace64e8398014c58b476101a47d4a4": "R8-final3"}  # FINAL3 /system (2026-11-06)
CLIPS = {"ref30": "otto_fps_30fps_1920x840_60s.mp4", "ref60": "otto_fps_60fps_1920x840_90s.mp4",
         "ref24": "otto_fps_24fps_1920x840_30s.mp4"}
INT64_MAX = 9223372036854775807

# GATE A: every remote command, verbatim. All read-only; root (su) only to read files.
DISCOVER = [
    ("props", "getprop | grep -E 'ro.boot.slot_suffix|ro.build.fingerprint|ro.build.version.release|sys.ly.protocol|sys.usb.config|debug.sf.enable_hwc_vds|sys.boot_completed'", False),
    ("uptime_boot", "cat /proc/uptime; cat /proc/sys/kernel/random/boot_id", False),
    ("monotonic", "grep -m1 'now at' /proc/timer_list", True),
    ("mountinfo_recorder", "grep -E 'libscreenrecord|otto' /proc/self/mountinfo", True),
    ("hashes", "sha256sum /system/lib/libscreenrecord.so /vendor/lib64/libsdmcore.so /dev/block/by-name/init_boot_b; cat /data/adb/otto/config/recorder_bitrate", True),
    ("display", "dumpsys display | grep -E 'renderFrameRate|DisplayModeRecord'", False),
    ("hwc_vds_log", "tail -n 5 /data/adb/otto/logs/hwc_vds.log", True),
    ("recorder_tail", "tail -n 40 /data/adb/otto/logs/recorder.log", True),
    ("processes", "ps -A -o PID,STIME,%CPU,RSS,NAME | grep -E 'lylink|lyscr|mdnsd|com.ap.play|mylink|otto|app_process|surfaceflinger'", False),
    ("sessions_tcp", "ss -tn state established | awk '{print \\$NF}' | grep -oE ':[0-9]+\\$' | sort | uniq -c", True),
    ("usb0", "ip -br link show usb0; ip -6 rule | grep -c 10500", True),
    ("thermal", "dumpsys thermalservice | grep -E 'Thermal Status|Temperature\\{' | head -20", False),
    ("gpu", "cat /sys/class/kgsl/kgsl-3d0/gpubusy /sys/class/kgsl/kgsl-3d0/gpuclk /sys/class/kgsl/kgsl-3d0/max_gpuclk", True),
    ("cpu_freq", "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq", False),
    ("foreground", "dumpsys activity activities | grep -m2 -E 'topResumedActivity|mResumedActivity'", False),
    ("video_viewers", "cmd package query-activities --brief -a android.intent.action.VIEW -d file:///sdcard/Download/otto_fps_test/x.mp4 -t video/mp4", False),
    ("video_viewers_mime", "cmd package query-activities --brief -a android.intent.action.VIEW -t video/mp4", False),
    ("packages_disabled", "pm list packages -d", False),
    ("packages_enabled", "pm list packages -e", False),
    ("sf_layers", "dumpsys SurfaceFlinger --list", False),
    ("storage", "df -h /sdcard | tail -1", False),
    ("location_speed", "dumpsys location | grep -m6 -E 'last location|Location\\[' | sed -E 's/[-0-9]+\\.[0-9]{3,},[-0-9]+\\.[0-9]{3,}/<coords>/g'", False),
]

SAMPLER = r"""
N=%(n)d; L='%(layer)s'; i=0; end=$(( $(cut -d. -f1 /proc/uptime) + N ))
while [ $(cut -d. -f1 /proc/uptime) -lt $end ]; do
  echo "@M $(grep -m1 'now at' /proc/timer_list | tr -dc 0-9)"
  head -1 /proc/stat | sed 's/^/@P /'
  echo "@G $(cat /sys/class/kgsl/kgsl-3d0/gpubusy 2>/dev/null) $(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)"
  echo "@T $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)"
  dumpsys SurfaceFlinger --frametimeline -all | grep -E '^Display Frame|Actual|Layer - TX -|Is Buffer|Present State' | sed 's/^/@L /'
  if [ $((i %% 10)) -eq 0 ]; then
    echo "@H $(dumpsys thermalservice | grep -m1 'Thermal Status' | tr -dc 0-9)"
    echo "@C $(ss -tn state established | grep -c ':7000 ')"
    echo "@F $(dumpsys activity activities | grep -m1 topResumedActivity | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | head -1)"
    echo "@R $(grep 'otto-r3 stats' /data/adb/otto/logs/recorder.log | tail -1)"
  fi
  echo "@E"
  i=$((i+1)); sleep 1
done
"""


class Otto:
    def __init__(self, ip, out):
        self.s = f"{ip}:{PORT}"; self.out = out; self.log = open(os.path.join(out, "runner.log"), "a")
        self.fails = 0

    def note(self, msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True); self.log.write(line + "\n"); self.log.flush()

    def sh(self, cmd, root=False, timeout=30):
        full = f"su -c \"{cmd}\"" if root else cmd
        try:
            r = subprocess.run([ADB, "-s", self.s, "exec-out", full], capture_output=True, timeout=timeout)
            self.fails = 0 if r.returncode == 0 else self.fails + 1
            return r.stdout.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            self.fails += 1; return ""

    def action(self, desc, argv, timeout=120):
        self.note(f"ACTION {desc}: {' '.join(argv)}")
        r = subprocess.run([ADB, "-s", self.s] + argv, capture_output=True, timeout=timeout)
        out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
        self.note(f"ACTION rc={r.returncode} {out[-300:]}")
        return r.returncode, out

    def connected(self):
        subprocess.run([ADB, "connect", self.s], capture_output=True, timeout=15)
        r = subprocess.run([ADB, "-s", self.s, "get-state"], capture_output=True, timeout=15)
        return r.stdout.strip() == b"device"


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()


def finish(out, verdict):
    with open(os.path.join(out, "RUN_VERDICT.txt"), "w") as f: f.write(verdict + "\n")
    with open(os.path.join(out, "SHA256SUMS.txt"), "w") as f:
        for n in sorted(os.listdir(out)):
            if n != "SHA256SUMS.txt": f.write(f"{sha256(os.path.join(out, n))}  {n}\n")
    print(f"\n== {verdict}\n== evidence: {out}", flush=True)


def discover(o):
    o.note("GATE A discover: read-only commands only")
    for name, cmd, root in DISCOVER:
        o.note(f"read {name}")
        with open(os.path.join(o.out, f"discover_{name}.txt"), "w") as f: f.write(o.sh(cmd, root))
        if o.fails >= 3: return "INCONCLUSIVE: ADB dropped during discovery"
    return "DISCOVER_DONE"


def mono_s(o):
    v = re.sub(r"\D", "", o.sh("grep -m1 'now at' /proc/timer_list", True))
    return int(v) / 1e9 if v else None


def ftl_rates(lines, match):
    """Rates from one 'dumpsys SurfaceFlinger --frametimeline -all' snapshot (last 64 display frames on display 0).
    Times are dump-relative ms, so every snapshot yields its own span: display composition rate, and the present rate
    of the layer whose name contains `match` (frames in which it presented a buffer)."""
    frames, cur, layer, isbuf = [], None, None, False
    for l in lines:
        if l.startswith("Display Frame"):
            cur = {"t": None, "hit": False}; frames.append(cur); layer = None
        elif cur is None: continue
        elif "Actual" in l and layer is None and cur["t"] is None:
            f = [x.strip() for x in l.split("|")]
            try: cur["t"] = float(f[3])
            except (IndexError, ValueError): pass
        elif "Layer - TX -" in l: layer, isbuf = l.split("Layer - TX -", 1)[1], False
        elif "Is Buffer?: 1" in l: isbuf = True
        elif "Present State : Presented" in l and layer and isbuf and match and match in layer: cur["hit"] = True
    pts = sorted((f["t"], f["hit"]) for f in frames if f["t"] is not None)
    if len(pts) < 2: return None, None, 0.0
    span = (pts[-1][0] - pts[0][0]) / 1000
    if span <= 0: return None, None, 0.0
    return round((len(pts) - 1) / span, 1), round(sum(1 for _, h in pts if h) / span, 1), round(span, 2)


def find_layer(o):
    # A17 lists layers as "RequestedLayerState{<id> <name> parentId=..}"; --latency needs the bare <name>.
    for l in o.sh("dumpsys SurfaceFlinger --list").splitlines():
        m = re.search(r"(SurfaceView\[[^ ]*#\d+)", l)
        if m and "Background" not in m[1] and "Bounds" not in m[1]: return m[1]
    return ""


def sample_phase(o, phase, secs, layer, rows, presents, abort):
    """One adb session per phase: root sampler streams 1 line-set per second; host parses live."""
    script = SAMPLER % {"n": secs, "layer": layer.replace("'", "")}
    b64 = base64.b64encode(script.encode()).decode()
    p = subprocess.Popen([ADB, "-s", o.s, "exec-out", f"echo {b64} | base64 -d | su -c 'sh -s'"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    raw = open(os.path.join(o.out, f"sampler_{phase}.txt"), "w")
    cur, prev_cpu, t0, k = {}, None, time.time(), 0
    for line in p.stdout:
        raw.write(line)
        tag, _, val = line.rstrip("\n").partition(" ")
        if tag == "@M": cur = {"mono": int(val) / 1e9 if val.isdigit() else None, "ftl": []}
        elif tag == "@P":
            v = [int(x) for x in val.split()[1:8]]
            if prev_cpu:
                d = [a - b for a, b in zip(v, prev_cpu)]; tot = sum(d) or 1
                cur["cpu"] = round(100 * (tot - d[3] - d[4]) / tot, 1)
            prev_cpu = v
        elif tag == "@G":
            g = val.split()
            if len(g) >= 3 and g[1] != "0": cur["gpu"] = round(100 * int(g[0]) / int(g[1]), 1); cur["gpumhz"] = int(g[2]) // 1000000
        elif tag == "@T" and val.strip().lstrip("-").isdigit(): cur["tmax"] = int(val) / 1000
        elif tag == "@L": cur.setdefault("ftl", []).append(val.strip())
        elif tag == "@H" and val: cur["thermal_status"] = int(val)
        elif tag == "@C": cur["hu_tcp7000"] = int(val or 0)
        elif tag == "@F": cur["fg"] = val
        elif tag == "@R": cur["r3_last"] = val
        elif tag == "@E":
            k += 1; m = cur.get("mono")
            disp, n1, span = ftl_rates(cur.get("ftl", []), layer)
            row = {"host_time": time.strftime("%H:%M:%S"), "phase": phase, "mono_s": f"{m:.3f}" if m else "NA",
                   "display0_frames_per_s": disp if disp is not None else "NA",
                   "video_layer_presents_per_s": n1 if (n1 is not None and layer) else "NA", "ftl_span_s": span,
                   "cpu_pct": cur.get("cpu", "NA"),
                   "gpu_busy_pct": cur.get("gpu", "NA"), "gpu_mhz": cur.get("gpumhz", "NA"),
                   "tmax_c": cur.get("tmax", "NA"), "thermal_status": cur.get("thermal_status", "NA"),
                   "hu_tcp7000": cur.get("hu_tcp7000", "NA"), "foreground": cur.get("fg", "NA")}
            rows.append(row)
            print(f"\r[{phase}] {k}  display0={row['display0_frames_per_s']}/s  video={row['video_layer_presents_per_s']}/s  cpu={row['cpu_pct']}%  "
                  f"gpu={row['gpu_busy_pct']}%@{row['gpu_mhz']}MHz  tmax={row['tmax_c']}C  "
                  f"r3={cur.get('r3_last', '-')[-48:]}", end="", flush=True)
            why = abort(cur)
            if why:
                p.kill(); raw.close(); print(); return why
    p.wait(); raw.close(); print()
    if k < secs * 0.6: return f"ADB stream ended early in {phase} ({k} samples in {secs} s)"
    return None


def r3_windows(log_text, phases, skip_lines=0):
    """R3 stats lines: '<mono s> otto-r3 stats <dt> ms: <kbit> kbit/s real=<n> synth=<n>' (time = window end).
    The log spans several boots and CLOCK_MONOTONIC restarts at each boot, so only lines appended after the
    preflight (skip_lines) are used; if the 1 MiB cap truncated the file meanwhile, the whole new file is used.
    Only windows lying fully inside a phase are counted."""
    out = collections.defaultdict(list)
    lines = log_text.splitlines()
    if len(lines) >= skip_lines: lines = lines[skip_lines:]
    for l in lines:
        m = re.match(r"(\d+\.\d+) otto-r3 stats (\d+) ms: (\d+) kbit/s real=(\d+) synth=(\d+)", l)
        if not m: continue
        t, dt, kb, re_, sy = float(m[1]), int(m[2]), int(m[3]), int(m[4]), int(m[5])
        for name, a, b in phases:
            if a is not None and b is not None and t - dt / 1000 >= a and t <= b: out[name].append((t, dt, kb, re_, sy))
    return out


def run(o, args):
    # phase = clip length minus ~6 s, so the measurement ends before the clip does
    phases_def = [("static", 30, None), ("ref30", 54, "ref30"), ("ref60", 84, "ref60")]
    if args.with_24: phases_def.append(("ref24", 24, "ref24"))
    phases_def.append(("recovery", 30, None))
    media = os.path.join(HERE, "media")
    for c in CLIPS.values():
        if not os.path.exists(os.path.join(media, c)): return f"INCONCLUSIVE: missing local clip {c}"

    o.note("preflight (read-only)")
    h = o.sh("sha256sum /system/lib/libscreenrecord.so", True)
    tcp = o.sh("ss -tn state established | grep -c ':7000 '", True).strip()
    last = o.sh("grep 'otto-r3 stats' /data/adb/otto/logs/recorder.log | tail -1", True).strip()
    nlines = o.sh("wc -l < /data/adb/otto/logs/recorder.log", True).strip()
    skip = int(nlines) if nlines.isdigit() else 0
    now = mono_s(o)
    fg0 = o.sh("dumpsys activity activities | grep -m1 topResumedActivity").strip()
    with open(os.path.join(o.out, "preflight.txt"), "w") as f:
        f.write(f"libscreenrecord {h}\nhu_tcp7000={tcp}\nlast_r3={last}\nmono={now}\nrecorder_log_lines={skip}\nforeground_before={fg0}\n")
    build = next((v for k, v in R3_SHAS.items() if k in h), None)
    if not build: return "INCONCLUSIVE: no known R3/R4 recorder active (hash mismatch); not comparable"
    o.note(f"recorder build: {build}")
    if tcp in ("", "0"): return "INCONCLUSIVE: no CarPlay session (no TCP to HU :7000); headless test not allowed"
    if not last or now is None or now - float(last.split()[0]) > 15:
        return "INCONCLUSIVE: recorder not producing R3 stats (no active projection session)"

    o.action("grant media read", ["shell", "pm", "grant", args.player.split("/")[0], "android.permission.READ_MEDIA_VIDEO"])
    # Just Player remembers the position per file name; a fresh name per run always starts at frame 0
    tag = os.path.basename(o.out).replace("run_", "r")
    o.action("push test clips", ["shell", f"mkdir -p {DEV_DIR}"])
    for c in CLIPS.values():
        rc, _ = o.action(f"push {c}", ["push", os.path.join(media, c), f"{DEV_DIR}/{tag}_{c}"], timeout=600)
        if rc: return f"INCONCLUSIVE: push failed for {c}"

    rows, bounds, verdict = [], [], None
    def abort(cur):
        if cur.get("hu_tcp7000") == 0: return "ABORT: CarPlay session lost (no TCP :7000)"
        if cur.get("thermal_status", 0) >= 3: return f"ABORT: thermal status {cur['thermal_status']}"
        return None
    try:
        for name, secs, clip in phases_def:
            layer = ""
            if clip:
                # -S: stop the test player before each clip, so a stale process from the previous clip or run cannot
                # leave the player in an error state (runs 063606 and the ref24 phase of 063946). Only our test player.
                cmd = ["shell", "am", "start", "-S", "-W", "-a", "android.intent.action.VIEW", "-t", "video/mp4",
                       "-d", f"file://{DEV_DIR}/{tag}_{CLIPS[clip]}", "-n", args.player]
                rc, out = o.action(f"start {clip}", cmd)
                if rc or "Error" in out: verdict = f"INCONCLUSIVE: playback start failed ({clip})"; break
                time.sleep(2)
                fg = o.sh("dumpsys activity activities | grep -m1 topResumedActivity")
                if "ResolverActivity" in fg or "ChooserActivity" in fg:
                    verdict = "INCONCLUSIVE: app chooser shown; rerun with --player"; break
                layer = "SurfaceView[" + args.player.split("/")[0]
                # playback must be proven before the phase counts: the player's SurfaceView presents buffers
                # -S cold-starts the player; allow up to ~8 s before deciding it does not play
                tapped = False
                for k in range(6):
                    d, n, sp = ftl_rates(o.sh("dumpsys SurfaceFlinger --frametimeline -all").splitlines(), layer)
                    o.note(f"playback check: display0={d}/s video layer={n}/s over {sp}s")
                    if n and n >= 0.6 * int(clip[3:]): break          # e.g. ref30 needs >= 18/s
                    if k >= 1 and not tapped:
                        # After a cold start (-S) the player sometimes stays paused on its first frames (seen 2026-10-31,
                        # state=PAUSED, frame 5). Only then: one tap on its centre play button. Never while it plays.
                        o.action("player paused: tap play", ["shell", "input", "tap", "960", "420"]); tapped = True
                    time.sleep(1.5)
                if not n or n < 0.6 * int(clip[3:]):
                    with open(os.path.join(o.out, f"logcat_fail_{clip}.txt"), "w") as f: f.write(o.sh("logcat -d -t 300", timeout=30))
                    verdict = f"INCONCLUSIVE: player did not present video for {clip} ({n} frames)"; break
            a = mono_s(o); o.note(f"PHASE {name} start mono={a}")
            presents = set()
            why = sample_phase(o, name, secs, layer, rows, presents, abort)
            b = mono_s(o); o.note(f"PHASE {name} end mono={b}")
            bounds.append((name, a, b))
            if why: verdict = why; break
    finally:
        o.action("return to home screen", ["shell", "input", "keyevent", "KEYCODE_HOME"])
        o.action("remove test clips", ["shell", f"rm -r {DEV_DIR}"])
        o.action("revoke media read", ["shell", "pm", "revoke", args.player.split("/")[0], "android.permission.READ_MEDIA_VIDEO"])

    log = o.sh("cat /data/adb/otto/logs/recorder.log", True, timeout=60)
    with open(os.path.join(o.out, "recorder.log"), "w") as f: f.write(log)
    with open(os.path.join(o.out, "phases.tsv"), "w") as f:
        for n, a, b in bounds: f.write(f"{n}\t{a}\t{b}\n")
    win = r3_windows(log, bounds, skip)
    res = os.path.join(HERE, "04_RESULTS.csv"); new = not os.path.exists(res)
    with open(res, "a", newline="") as f:
        w = csv.writer(f)
        if new: w.writerow(["run", "kind", "phase", "mono_s", "metric", "value"])
        rid = os.path.basename(o.out)
        for r in rows:
            for k in ("display0_frames_per_s", "video_layer_presents_per_s", "ftl_span_s", "cpu_pct", "gpu_busy_pct", "gpu_mhz", "tmax_c", "thermal_status", "hu_tcp7000"):
                w.writerow([rid, "1s", r["phase"], r["mono_s"], k, r[k]])
        for n, ws in win.items():
            for t, dt, kb, re_, sy in ws:
                w.writerow([rid, "r3_10s", n, f"{t:.3f}", "real_per_s", f"{re_ * 1000 / dt:.2f}"])
                w.writerow([rid, "r3_10s", n, f"{t:.3f}", "synth_per_s", f"{sy * 1000 / dt:.2f}"])
                w.writerow([rid, "r3_10s", n, f"{t:.3f}", "kbit_s", kb])
    o.note("R3 per phase (full 10-s windows only): " + "; ".join(
        f"{n}: n={len(ws)} real={sum(x[3] for x in ws) * 1000 / max(1, sum(x[1] for x in ws)):.1f}/s "
        f"synth={sum(x[4] for x in ws) * 1000 / max(1, sum(x[1] for x in ws)):.1f}/s" for n, ws in win.items()))
    return verdict or "RUN_COMPLETE (MIB4 panel: NOT MEASURED)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--otto", required=True); ap.add_argument("mode", choices=["discover", "run"])
    ap.add_argument("--approve-gate-b", action="store_true"); ap.add_argument("--player", default=PLAYER)
    ap.add_argument("--with-24", action="store_true")
    a = ap.parse_args()
    if a.mode == "run" and not a.approve_gate_b:
        sys.exit("GATE B not approved: 'run' starts video playback on OTTO. Add --approve-gate-b only with the owner's approval.")
    out = os.path.join(HERE, "runs", f"{a.mode}_{time.strftime('%Y%m%d_%H%M%S')}"); os.makedirs(out)
    o = Otto(a.otto, out)
    if not o.connected():
        finish(out, f"INCONCLUSIVE: no ADB connection to {o.s}"); return
    finish(out, discover(o) if a.mode == "discover" else run(o, a))


if __name__ == "__main__":
    main()
