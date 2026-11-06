# Recorder R3 — projection bitrate (FINAL2 era; FINAL3 runs R8 from /system, `src/recorder/`, R8)

R2 (`../recorder2`) plus: bitrate read from `/data/adb/otto/config/recorder_bitrate` for the standby scrcpy server and
every session (without the file it behaves exactly like R2: 4 Mbit/s), and encoder stats every 10 s in
`/data/adb/otto/logs/recorder.log`.

On OTTO (no flash, nothing written to /system):
| Device path | From here |
|---|---|
| `/data/adb/otto/rec_test/libscreenrecord.so` | built from `otto_screenrecord_a17_r3.c` (Termux clang 21.1.8, armv7a, -O2 -mthumb), sha256 `6b38d2dfe5c6ff63a350f6c79d2c826fe5af6e4d1eb866e2239331932c2903c0` |
| `/data/adb/post-fs-data.d/90-otto-rec-test.sh` | `90-otto-rec-test.sh` — sha-guarded bind mount over `/system/lib/libscreenrecord.so` |
| `/data/adb/otto/rec_test/otto_rec_test.sh` | `otto_rec_test.sh` — `status | set N | apply | off` |
| `/data/adb/otto/config/recorder_bitrate` | `recorder_bitrate` (8000000) |

Car result 2026-10-26: 8 Mbit/s looked smear-free at first, but the owner reports the smear returned later that day
(correction 2026-10-31). Successors R5–R7: `src/` (running) and `attic/` (superseded, failed, parked).
The binary is not in git (`*.so`). Owner's original notes (Danish): `LAES_MIG.txt`.
