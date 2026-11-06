# CarPlay projection at 60 fps (Android screen → car as H.264)

**Result on OTTO (2026-11-06):** the car's MIB4 panel showed 1162 of 1168 source pictures of a 60 fps test video
(99.5 %, ≈ 59.7 fps), measured with a phone camera (guide 06).

## How the chain works
```
Android display ──► virtual display (scrcpy-server) ──► H.264 encoder ──► our libscreenrecord.so ──► OEM lyscrservice ──► car
```
- The OEM screen service calls a small C interface: `ScreenRecord_Create()`, then `init(w, h, fps, bitrate, callback)`,
  `start()`, `stop()`. The callback takes codec config (SPS/PPS) and one Annex-B frame at a time.
- Our replacement library (`../../src/recorder/otto_screenrecord_a17_r8.c`) keeps that interface and runs
  `scrcpy-server` (from `/system/etc`) to produce H.264. Freestanding C, only libc + liblog.

## What made the difference
| Setting | Why |
|---|---|
| **H.264 High profile** | what the OEM's own recorder sent for CarPlay |
| **QP bounds 25–40** | without a ceiling the encoder went to QP 51 in fast motion: blocky, "smeared" picture. The OEM recorder used the same bounds |
| **12 Mbit/s** | from a config file (`/data/adb/otto/config/recorder_bitrate`), no rebuild needed to try another value |
| **no B-frames** | lower latency |
| **hardware-composed virtual display** | see below |
| **retry scrcpy start** a few times in the first 90 s | the first attempt early in boot can fail ("Could not create display") |

## The 56-vs-59 fps race
If the virtual display is created very early in boot, SurfaceFlinger composes it on the **GPU** (`isGpu=true` in
`dumpsys SurfaceFlinger`, under the `scrcpy` display). We measured 56.2 encoded frames/s that way, 59.2 with hardware (HWC)
composition. Re-creating the display later gets HWC. A script that does this once per boot is in
`../../attic/failed-or-parked/vds-recreate/` (we proved it, and did not install it: 56 was good enough in the car).

## How to measure
- The library logs encoder statistics every 10 s (frames/s, real vs. repeated frames, Mbit/s).
- `dumpsys SurfaceFlinger | grep -A8 'name="scrcpy"'` → `isGpu=`.
- What the car actually shows: guide 06.

## Smear we did not fix
Rare smear can come from the OEM transport library, which drops packets when its queue is full ("pkt queue overfull" in
logcat). `../../tooling/diagnostics/smearwatch.sh` logs those lines with wall time, so you can match a smear you saw to a cause.
