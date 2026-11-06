# Incident 2026-10-25 — OTA1 left OTTO unable to boot

Severity: P0 (device dead to the user). Status: **RESOLVED** (device recovered, same day). Root cause: **UNKNOWN** (narrowed, see 6).

## 1. Last known good before the incident
- Image: OTTO_A17_FINAL, expanded super SHA-256 `e0360bd2067c82e60af3faefcf44e02434ce640b2ac8fc03bf7db812e76c944b`.
- Written 2026-10-25 04:48 by `otto_r119_win_final.py` (R119 Windows): SELFTEST=PASS, 6144/6144 MiB, written=2272, same=3872,
  full readback, RESULT=FLASH_PASS (`Download/R119_WIN_LOG.txt`). Slot `_b`.

## 2. What was installed
- Package: `otto_ota_1.zip`, 2138664287 B, SHA-256 `6378a231165d4c565c52dc8561b32ef10a89945422c7fb6e3a861e3117c4dd01`.
- Built 2026-10-25 08:49–08:54 by `qfil/otto/final_build/build/otto_ota_build.py` with avbroot 3.37.1 `payload pack`,
  signed with `~/OTTO/keys/ota/otto_ota.key`. Payload 2138663641 B (sha prefix `b5d57a213c485a61`), max_timestamp 1792918182.
- Installed with `otto_ota_install.sh` → `otto_ota.dex apply` → update_engine (Virtual A/B, compression, lz4, cow v2) to slot `_a`.

## 3. Intended writes (from the build log, preserved here because the log file was deleted 25.10 with owner approval)
- Dynamic (snapshots in /data): odm, system, system_dlkm, vendor, vendor_dlkm — FINAL images + 3 files in system
  (OttoLauncher.apk v10 `d8c6382b…`, otto_navi.sh 0.7 `03536c10…`, otto_firstboot.sh `9ffee157…`);
  fresh unsigned AVB hashtree footers added to system (4335861760→4379901952 B) and vendor (841355264→850792448 B).
- Firmware, copied from a verified dump of slot `_b`: abl bluetooth boot devcfg dsp dtbo featenabler hyp imagefv init_boot keymaster
  modem qupfw recovery rpm tz uefisecapp vbmeta vbmeta_system vendor_boot xbl xbl_config (22).
- Skipped (SELinux denied update_engine in a test): cmnlib cmnlib64 mdtp mdtpsecapp multiimgoem.

## 4. Symptoms
- After reboot OTTO did not start at all (no usable screen). EDL (9008) still reachable via button.

## 5. Measured state (EDL, read-only, 2026-10-25 19:17, `qfil/otto/OTTO_RESCUE/DIAG_20261025_191728/`)
- All 27 `_a/_b` partition pairs **byte-identical** → firmware writes were correct and are not the cause.
- GPT: `_a` active on all pairs, type GUIDs swapped to `_a` (QTI eMMC scheme; inactive GUID `77036cd4-03d5-42bb-8ed1-37e5a88baa34`).
- `boot_a` retry count 7 → 4: ABL loaded the `_a` kernel three times; failure is after ABL (Android/first-stage init), and the
  device hangs instead of rebooting, so ABL never fell back to `_b`.
- misc @0x8000 (misc_virtual_ab_message): version 2, merge_status **SNAPSHOTTED**, source slot `_b`.

## 6. Root cause
UNKNOWN. Proven not firmware. Most likely: first-stage init on `_a` failing to assemble the snapshot-backed dynamic partitions
(avbroot-generated payload / CoW, or the added hashtree footers), then hanging. Not investigated further by owner decision.

## 7. Recovery performed
1. `otto_rescue.py setslot-b` (EDL): GPT both copies — `_b` attrs 0x7f (prio 3, active, retry 7, successful), `_a` 0x80 (unbootable),
   type GUIDs swapped back on 24 pairs (recovery, init_boot, vbmeta_system not swapped, as found); misc merge_status → CANCELLED.
   Guard: writes only if live bytes equal the diagnose dump or the fixed state. Simulation-tested (normal, re-run, undo, cable pull, foreign state).
2. Boot on `_b`; Android cleaned snapshots (misc now NONE, /metadata/ota empty); postboot 57/57 PASS.
3. OTA1's three files delivered instead by FINAL2 via EDL (super only); postboot 58/58 PASS.

## 8. Decisions / policy
- Owner: **never OTA again; changes only via EDL or bootloader.** OTA client removed from FINAL2 (V45).
- OTA artifacts deleted 25.10 (owner approved): `OTTO_A17_OTA1/`, `~/otto_final_build/ota1/`. Build script and client source kept as history.
- Lesson: the OTA rewrote the whole boot firmware of the other slot to deliver three files; method risk >> change size.
