#!/usr/bin/env python3
"""OTTO camera benchmark (D): how many distinct pictures per second the MIB4 panel really shows.

Input: the owner's phone video of the MIB4 while OTTO plays otto_fps_60fps_1920x840_90s.mp4 (testsrc2 pattern, burned-in
frame counter and a yellow block that moves 24 px to the right on EVERY source frame, wrapping at the right edge).
Method: find the yellow block in every camera frame (HSV threshold, largest blob), take its x centre, and count position
changes. Each change is a new picture on the panel. A camera at 120/240 fps (slow motion) sees every panel picture
several times, so "changes per second" = distinct pictures per second; a step of two block widths = a skipped picture.
Self-test: run it on the source clip itself -> 60.0 changes/s, 0 skips.
Usage: python3 -I camera_analyze.py <video.mp4> [--start S] [--dur S]  -> prints the result, writes <video>.camera.txt
"""
import argparse, subprocess, sys
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("video"); ap.add_argument("--start", type=float, default=0.0); ap.add_argument("--dur", type=float, default=0.0)
ap.add_argument("--crop", default="", help="x:y:w:h in source pixels: the CarPlay picture area of the MIB4 in the camera frame")
ap.add_argument("--cam-fps", type=float, default=0.0, help="real capture rate of a slow-motion file (com.android.capture.fps); --start/--dur are then file seconds")
a = ap.parse_args()
W = 640
info = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height,avg_frame_rate",
                       "-of", "csv=p=0", a.video], capture_output=True, text=True).stdout.strip().split(",")
w0, h0 = int(info[0]), int(info[1])
if a.crop: w0, h0 = int(a.crop.split(':')[2]), int(a.crop.split(':')[3])
num, den = info[2].split("/"); cam_fps = a.cam_fps or float(num) / float(den)
H = int(round(h0 * W / w0 / 2) * 2)
cmd = ["ffmpeg", "-v", "error"]
if a.start: cmd += ["-ss", str(a.start)]
cmd += ["-i", a.video]
if a.dur: cmd += ["-t", str(a.dur)]
cx, cy, cw, ch = (a.crop.split(":") if a.crop else ("0", "0", "0", "0"))
# ffmpeg's crop is w:h:x:y
cmd += ["-vf", (f"crop={cw}:{ch}:{cx}:{cy}," if a.crop else "") + f"scale={W}:{H}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
xs = []; ws = []
while True:
    b = p.stdout.read(W * H * 3)
    if len(b) < W * H * 3: break
    f = np.frombuffer(b, np.uint8).reshape(H, W, 3).astype(np.int16)
    r, g, bl = f[..., 0], f[..., 1], f[..., 2]
    yellow = (r > 170) & (g > 150) & (bl < 110) & (np.abs(r - g) < 70)
    # The pattern has a static full-height yellow colour bar; the moving block lives only in the bottom band. Count
    # yellow in the bottom band and drop columns that are also yellow higher up (the bar). Over the bar the block is
    # invisible (yellow on yellow): those frames give no position.
    top = yellow[int(H * 0.45):int(H * 0.60)].sum(axis=0) > 0
    cols = yellow[int(H * 0.78):int(H * 0.92)].sum(axis=0) * (~top)
    if cols.max() < 3: xs.append(np.nan); ws.append(0); continue
    # largest run of yellow columns = the block (the pattern has little pure yellow)
    on = cols >= max(3, cols.max() * 0.5)
    best, cur, start, bs = 0, 0, 0, 0
    for i, v in enumerate(on):
        if v:
            if cur == 0: start = i
            cur += 1
            if cur > best: best, bs = cur, start
        else: cur = 0
    xs.append(bs + best / 2.0); ws.append(best)
xs = np.array(xs); ws = np.array(ws, dtype=float)
# Only frames that show the WHOLE block count: next to the colour bar a partly hidden block moves its centre by half a
# step and would be miscounted (self-test: 130 half steps out of 1000).
medw = np.median(ws[ws > 0]) if np.any(ws > 0) else 0
xs[np.abs(ws - medw) > 0.2 * medw] = np.nan
n = len(xs); dur = n / cam_fps
d = np.diff(xs)
valid = ~np.isnan(d) & (d > -W * 0.5)            # drop wrap-arounds and frames without a block
step_est = np.median(d[valid & (d > 1.0)]) if np.any(valid & (d > 1.0)) else np.nan
moves = d[valid]
thr = step_est * 0.35
changes = int(np.sum(moves > thr))
skips = int(np.sum(moves > step_est * 1.6))
ok = valid.sum()
# Index method (robust to a camera that catches the panel mid-change): the source block advances one step per source
# frame. Fit the step from the block's speed (source = 60 pictures/s), turn every position into a picture index, and per
# wrap segment count the indices the panel actually showed (distinct) and the ones it never showed (dropped).
t = np.arange(n) / cam_fps
shown = dropped = 0; seg_time = 0.0; steps = []
good = ~np.isnan(xs)
seg = []
def close(seg):
    global shown, dropped, seg_time
    if len(seg) < int(cam_fps * 0.3): return
    st = np.array(seg); tt, xx = st[:, 0], st[:, 1]
    speed = np.polyfit(tt, xx, 1)[0]                       # px per second on screen
    if speed <= 0: return
    step = speed / 60.0; steps.append(step)
    k = np.round((xx - xx[0]) / step).astype(int)
    # a picture counts as shown when its index is seen in 1 or more camera frames
    ks = np.unique(k); shown += len(ks); dropped += int(ks.max() - ks.min() + 1 - len(ks)); seg_time += tt[-1] - tt[0]
for i in range(n):
    if good[i] and (not seg or (xs[i] >= seg[-1][1] - 2 and t[i] - seg[-1][0] < 0.2)): seg.append((t[i], xs[i]))
    else:
        close(seg); seg = [(t[i], xs[i])] if good[i] else []
close(seg)
idx_line = (f"index method: {shown} distinct pictures shown, {dropped} never shown, over {seg_time:.1f} s of visible block"
            f" -> {shown / seg_time:.1f} distinct/s, {dropped / seg_time:.1f} dropped/s (step {np.median(steps) if steps else float('nan'):.1f} px)\n") if seg_time else "index method: no usable segments\n"
res = idx_line + (f"camera {cam_fps:.1f} fps, {n} frames ({dur:.1f} s), block found in {np.sum(~np.isnan(xs))} frames\n"
       f"block step on screen: {step_est:.1f} px (at {W} px width)\n"
       f"panel picture changes: {changes} over {ok / cam_fps:.1f} s -> {changes / (ok / cam_fps):.1f} distinct pictures/s\n"
       f"steps of ~2 pictures (a picture skipped between two camera frames): {skips}\n"
       "Reading: at 120/240 fps camera, distinct pictures/s is what the MIB4 showed; 60 = every source frame.\n")
print(res)
open(a.video + ".camera.txt", "w").write(res)
