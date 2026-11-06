# OTTO release timeline and milestone index

Three truths are kept apart: **Repository** (source + build), **Firmware** (what was written, by hash),
**Runtime** (what was proven on the device; *bench* ≠ *car*). Strength: M = measured log/hash, D = document claim not re-verified here.

| Date | Event | Truth | Result | Proof | Strength |
|---|---|---|---|---|---|
| Sep 2026 | Root, EDL/Sahara/Firehose bring-up; R29E first physical init_boot_b write + readback | Firmware | PASS | migration `04_SCRIPTS/edl/root_writer_R29E_proven_reference.py`; master mission §2 | D |
| Sep–Oct | QIL track (R65–R118), DSU A17 experiments, 60 Hz, NAVI, launcher stages | mixed | QIL superseded | `/root/qcom-image-loader` commit `adb7295`; `~/OTTO/00_MASTER_STATE/*` | D |
| 2026-10-18 | A13 super backed up (raw sha `2c85626c…`, gz `7c277039…`); A17 super image built (`3072c0c6…` expanded) | Firmware | PASS | `OTTO_A17_PERMANENT_MIGRATION/06_CHECKSUMS/`; gz re-verified 25.10 | M |
| 2026-10-19 | Recovery gates G1 ABL fastboot, G2 fastbootd, G3 EDL read: PASS; DSU → permanent A17 migration | Firmware+Runtime | PASS | `07_RECOVERY/RECOVERY_GATE_PASS.env`, `05_LOGS/migration_20261019_165848` | M |
| 2026-10-22/23 | R117/R119 live flash runs (Termux, then Windows) of the A17 image | Firmware | partial → PASS | `qfil/R117_A17_LIVE_FLASH_*`, `R119_STREAM_WRITER/RUN_20261023_*` | D (not re-read) |
| 2026-10-24 | FINAL build (Magisk modules baked in, launcher v9, OTA client) raw `e0360bd2…` | Repository | built | `OTTO_A17_FINAL/BUILD_LOG.txt`, `SHA256SUMS.txt` | M |
| 2026-10-25 04:48 | FINAL written by R119 Windows, full readback | Firmware | FLASH_PASS | `Download/R119_WIN_LOG.txt` | M |
| 2026-10-25 08:42–09:25 | Car session on FINAL: CarPlay chain up (HU sockets 3, 1920x840@60), car GPS fix, 10-min drive log | Runtime (car) | PASS (partial); Maps smear when panning reported | `OTTO:/data/local/tmp/otto_car_car1.txt`, `otto_drive_1025_0915.txt` | M |
| 2026-10-25 ~09–19 | OTA1 installed to `_a` → no boot | Runtime | **FAIL (P0)** | `INCIDENT_20261025_OTA_BLACK_SCREEN.md` | M |
| 2026-10-25 19:17 | EDL diagnose (read-only) | Firmware | all 27 pairs identical | `OTTO_RESCUE/DIAG_20261025_191728` | M |
| 2026-10-25 ~19:30 | setslot-b + VAB cancel; boot `_b` | Firmware+Runtime | PASS 57/57 (bench) | `OTTO_RESCUE/RESCUE_LOG.txt`, postboot report | M |
| 2026-10-25 18:44 (build) / ~19:50 (flash) | FINAL2 = FINAL + launcher v10 + NAVI 0.7 + firstboot 25.10 − OTA client; raw `ce324a07…` | Repository+Firmware | built, selftest PASS, flashed | `OTTO_A17_FINAL2/` | M |
| 2026-10-25 20:05 | FINAL2 runtime | Runtime (bench) | **PASS 58/58** | postboot report on OTTO | M |
| 2026-10-26 | FINAL2 in the car | Runtime (car) | accepted | `docs/history/2026-10-26-car-session.md` | M |
| 2026-10-31/11-01 | Final candidates F1–F23 tested live from `/data`; GPS satellites extras proven on a drive | Runtime (car) | PASS | `docs/history/2026-10-31-chain-test-and-final-prep.md`, `evidence/2026-11-01-gps-searching/` | M |
| 2026-11-01 | FINAL3 R2 = FINAL2 + 11 files in `system_b` (R8, F10/F10b, F3/F4/F14, F13, F23, cargps satellites, launcher v18); raw `5cac1165…` | Repository | built, selftest PASS | `firmware/final3/` | M |
| ≤ 2026-11-03 | FINAL3 written by R119 Windows (`otto_r119_win_final3.py` `b7aee127…`); first boot 2026-11-06 | Firmware | FLASH_PASS (owner report) | owner, 2026-11-03 | D |
| 2026-11-06 | FINAL3 post-boot 74/74; benchmark A–F; launcher v21b app update; drive G | Runtime (car) | **PASS, project closed** | `evidence/2026-11-06-final3-benchmark/` | M |

## Image hash register
| Expanded SHA-256 | Image | Where |
|---|---|---|
| `2c85626c189f0f5b1fccf8b4dbd2b92c036ca2ebbc893acf52922bd3f5d932ee` | Original A13 super (device dump 18.10) | migration `01_BACKUPS/a13_super` |
| `3072c0c6c74c6e223d9cee1e182a01929011115555d9a50cba71891264389150` | A17 super 18.10 (pre-FINAL) | `qfil/otto/OTTO_A17_super.simg` |
| `e0360bd2067c82e60af3faefcf44e02434ce640b2ac8fc03bf7db812e76c944b` | FINAL (24.10) | `qfil/otto/OTTO_A17_FINAL/` |
| `ce324a0714bde6773da3c14ab03dea3615bf37a1908ff49965cc8f0d8da764e6` | FINAL2 (25.10) — fallback | `qfil/otto/OTTO_A17_FINAL2/` |
| `5cac116531d47d02a36348738f2748f9021a2511d2e8ac1451b18157a804c576` | FINAL3 R2 (01.11) — **running** | `qfil/otto/OTTO_A17_FINAL3/` |

The master mission's "hash conflict" (`3072c0c6…` vs `e0360bd2…`) is two different images, not an error.
