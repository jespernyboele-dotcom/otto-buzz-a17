# 2026-10-31 — FPS chain test, optical 60 fps on the MIB4, candidates for the last A17 build

OTTO: FINAL2 on slot `_b`, parked car (VW ID. Buzz, MIB4), CarPlay active, read and driven over Wi-Fi adb.
Nothing flashed. Raw evidence stays outside git:
- `Download/OTTOBUZZ_MIB4_UNATTENDED_FPS_20261031/` (runner runs, `06_ANALYSIS.md`)
- `Download/OTTO_A17_ULTIMATE_FINAL_PREP_20261031/` (candidates, `00_README.md`)
- `Download/OTTO_BILSESSION_20261031/` (morning pull, `ANALYSE_20261031.md`)

## Chain test (tests/fps-chain)
Unattended runner: plays offline-made 30 and 60 fps clips with a unique frame counter in Just Player 0.217 (F-Droid, installed for tests). It measures each link:
- display 0 and the video layer (SurfaceFlinger `--frametimeline`)
- encoder AUs (R3 `recorder.log`)
- CPU, GPU and temperature

| Link (60 fps clip, 8–12 Mbit/s, VDS=1) | Result |
|---|---|
| Player → video layer | 61/s |
| Display 0 composition | 60.0/s |
| Capture + encoder (`real`) | 60.0/s |
| R3 cadence engine | **+10.3 synthetic AU/s → ~70 AU/s sent**: the first link off 60 Hz |
| R4/R5 (25 ms deadline) | 59.8 real + 0.2 synthetic |
| R7 (High profile) | 59.7 real, 0 synthetic, CPU 30 % (R6: 39 %) |

Bitrate sweep (R4, 4.19 / 8 / 10 / 12 Mbit/s): 60 real AU/s at every rate. Delivered rate is slightly above the setting (12 → 12.29). The owner chose 12 Mbit/s.

## Optical check on the MIB4 (first ever)
The owner filmed the MIB4 at 60 fps for 66 s during the R7 60 fps phase.
- The panel shows the High-profile picture correctly.
- The burned-in counter advances 60.0 frames/s (2206 → 3346 in 19 s).
- Tracking the moving block over 733 camera-frame pairs:
  - 83 % one source frame forward
  - 11.5 % partial (the camera caught a change)
  - 5.3 % unchanged
  - 0.1 % two forward
- So the MIB4 displays **about 57–60 distinct frames/s**. The ~5 % could be real repeats, camera/panel beat, or tracking noise.

## OEM A13 recorder used High profile for CarPlay
`MiniCap_Create` in the OEM `libscreenrecord.so`: `property_get("sys.ly.protocol")`:
- `"raa"` (Android Auto) → profile 1, level 0x20
- otherwise (CarPlay `rcp`) → **profile 8 (High), level 0x200**

All OTTO recorders since R2 forced Baseline (`profile=1`), because the cadence engine needs CAVLC.

## Boot
- Android itself is done at ~29 s (`BOOT_COMPLETED`).
- FINAL2's `run.sh` ran the service.d scripts one after another, so their settle times added up:
  - VDS confirmed at ~190 s
  - SurfaceFlinger/GPU placement at ~150 s
- With F3/F4: VDS at 38–39 s, bootrecorder stop 50 s, placement ~83 s. Verified on 6 boots.
- Recorder: the first scrcpy start fails once on every boot ("no data within 3 s", the server starts before the display is on).
  - In boot `cac97410` the second start failed too. R3 fell back to screenrecord, and lylinkservice then rebooted the box (reason `reboot`, not shell).
  - R6 allows 5 starts during the first 90 s: 4/4 boots without fallback, first frame at 26.2–27.8 s.
- The boot animation is never visible in the car (owner, again).

## GPS and clock
- OTTO has no battery-backed clock and boots at the build date (2026-05-16) until network time.
- `otto_cargps` judged freshness by the wall clock, so car fixes are rejected until then. Seen: `stale=7` at boot. Offline: 120/120 rejected with an unset clock.
- F6 accepts fixes that arrive one GPS second apart.
- F7 sets the clock from the car's UTC. **Proven live**: `clock: set from car UTC … rc=0 (was Sat May 16 …)`. NAVI (AA server + MIB4 pipe) started 1 s later.
- This is **not** the explanation of the 26 Oct "Searching for GPS". Fixes were fresh then. The best hypothesis stays OTTO's own weak GNSS status in the car.

## Corrections
- Owner: 8 Mbit/s did **not** remove the projection smear on 26 Oct; it returned later that day. `recorder3/README.md` and `STATUS_AND_ROADMAP.md` are corrected.
- `real` in R3 stats = encoder access units, an upper bound on distinct pictures. A static Maps screen still gives ~12/s, because Maps redraws at ~18 fps while idle (location updates ~2/s).

## Process errors (recovered, all documented in the run folders)
- Overwriting the bind-mounted library with `cp` crashed the recorder and rebooted OTTO. Replace with a new file + `mv`.
- A reboot right after writing `recorder_bitrate` without `sync` left it zero-filled (one run at 4.19 Mbit/s).
- Overlapping background tasks: a reboot interrupted a running test.

## State left on OTTO
- Recorder R7 active (R3–R6 kept in `/data/adb/otto/rec_test/`), 12 Mbit/s.
- F3, F4, F6, F7 via `/data/adb/post-fs-data.d/91-otto-final-test.sh`.
- Just Player installed.
- All reversible. See `docs/history/2026-10-31-final-candidates-table.md`.

## Open before the final build
1. A drive with R7 + 12 Mbit/s: smear when panning? (owner)
2. Drive without network to see F6/F7 on the road, plus `drive` logging for "Searching for GPS".
3. `extras` with tap, music and route (#6, #8, #12, UDP legs).
