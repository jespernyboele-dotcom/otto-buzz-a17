# OTA policy and rollback

**Policy (owner decision, 2026-10-25): OTTO is never updated over the air again. Every change ships as an image flashed via
EDL (or ABL fastboot), changing only what must change — normally `super` on slot `_b`.**

Why: OTA1 (Virtual A/B, full payload) rewrote the firmware of the inactive slot to deliver three files and left the device
unbootable (`INCIDENT_20261025_OTA_BLACK_SCREEN.md`). The flash path is proven, resumable, read-back verified and reversible.

State in FINAL2:
- OTA client `/system/etc/otto/otto_ota.dex` removed (postboot V45). The GSI's `update_engine` stays (part of Android) but has no client;
  `update_engine_client` is absent in the GSI. Automatic system updates off (V26).
- `/system/etc/security/otacerts.zip` still holds the OTTO OTA certificate (harmless without a client).
- OTA signing key `~/OTTO/keys/ota/otto_ota.key` still exists — **secret, never in git**; may be destroyed by owner decision.
- `otto_ota_build.py` and `final_build/ota/src` are kept only as incident history. No installer is published.

Rollback for any image change:
1. Keep the previous image folder (e.g. `OTTO_A17_FINAL`) until the new one has passed bench **and** car acceptance.
2. Rollback = flash the previous image with its own writer (EDL_RECOVERY_RUNBOOK §2.5).
3. Slot problems → EDL diagnose first; never guess at GPT writes.
