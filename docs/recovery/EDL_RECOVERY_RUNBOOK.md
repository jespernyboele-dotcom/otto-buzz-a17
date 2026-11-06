# OTTO EDL recovery runbook

> **Every command marked WRITE can brick the device or erase data.** Nothing here runs automatically, from CI,
> or on USB detection. Each write needs the owner's explicit go and a typed confirmation word.

## 0. Lifelines, in order of preference
| Path | How to reach | Last proven | Notes |
|---|---|---|---|
| EDL 9008 (Sahara → goco7 → Firehose) | power off, hold EDL button, plug USB to PC | **2026-10-25** (diagnose, setslot-b, FINAL2 flash) | Always available (boot ROM). The only guaranteed path. |
| ABL fastboot | `adb reboot bootloader` (needs a booting Android) | 2026-10-19 (gate G1) | Not re-tested after migration. |
| fastbootd (patched recovery) | from ABL / adb | 2026-10-19 (gate G2, operator attested) | Not re-tested. |

## 1. Tools (Windows PC, `C:\otto`)
- Python 3, `pyusb`, `libusb-package` (wheels in `qfil/otto/installer/wheels`), WinUSB on `QUSB__BULK` via Zadig 2.9.
- `goco7.bin` (Firehose programmer, SHA-256 `f7799eb9e38177ff7c7776e472b11c0e54c46e0a984232e3705000719cf30bba`), in `C:\otto`.
- Writers: `OTTO_A17_FINAL2\otto_r119_win_final2.py` (super only), `OTTO_A17_FINAL\otto_r119_win_final.py`,
  `OTTO_RESCUE\otto_rescue.py` (GPT/misc). **After copying from the phone, check size + `certutil -hashfile … SHA256`**
  — an MTP copy truncated a script on 25.10 (it then exits silently).

## 2. Decision tree
1. **Device boots Android?** → do nothing here; use adb.
2. **Doesn't boot** → EDL, then `py otto_rescue.py diagnose` (read-only). Copy `DIAG_*` back for analysis.
3. Diagnose shows the active slot is not the known-good one, or a VAB update is pending → a *targeted* GPT/misc fix
   (the 25.10 `setslot-b` is bound to that day's dump by SHA and refuses any other state; a new incident needs a new, reviewed fix).
4. Slot is right but Android on it is broken → re-flash super:
   `py otto_r119_win_final2.py selftest` → `preflight` → `flash` (type FLASH). Writes super only, pre-reads each MiB,
   skips identical ones, reads back every written MiB, then verifies all 6144 MiB against the image SHA. Resumable via its ledger.
5. FINAL2 itself suspected → same with `OTTO_A17_FINAL` (delete `R119_LEDGER_a17.txt` first, or it reports "done").

## 3. Known-good images
| Image | Expanded SHA-256 | Writer |
|---|---|---|
| FINAL3 R2 (running) | `5cac1165…` | `otto_r119_win_final3.py` (`b7aee127…`) |
| FINAL2 | `ce324a07…` | `otto_r119_win_final2.py` |
| FINAL | `e0360bd2…` | `otto_r119_win_final.py` |
| A13 original super | `2c85626c…` (gz `7c277039…`, re-verified 25.10) | **none ready on EDL** — see 4 |

## 4. Back to Android 13 — NOT TESTED
- Backup: `Download/OTTO_A17_PERMANENT_MIGRATION/01_BACKUPS/a13_super/OTTO_A13_super_mmcblk0p19_raw.img.gz` (raw, gzip).
- Existing script: `07_RECOVERY/recover_flash_super.sh a13` — **ABL fastboot** path (gunzip → sha check → `fastboot flash super`,
  `erase userdata`, `erase metadata`, set slot b). Never executed.
- EDL path: the R119/FINAL writers accept only an Android sparse image with a hard-coded expanded SHA; an A13 EDL restore would
  need `img2simg` of the raw image and a writer copy bound to `2c85626c…`. Not built.
- Before any A13 restore, confirm the boot chain: the migration plan states boot_b/init_boot_b/vendor_boot_b/dtbo_b/vbmeta_b were
  unchanged by the migration, i.e. they are the chain A13 ran on; slot `_a` firmware is now identical to `_b` (diagnose 25.10).
  CarPlay keys live in privdata1 (never written).
- Consequence: user data is erased; A13 starts factory-fresh.

## 5. Never
- No OTA / update_engine. No `wipe-userdata` unless the owner asks. No writes from scripts copied without a hash check.
