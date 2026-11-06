# START HERE — OTTO in five minutes

**What it is:** an Ottocast P3 Pro (Qualcomm SM6225, eMMC, unlocked) moved from its stock Android 13 to an Android 17 GSI with
the OEM CarPlay/RCP chain kept, connected to a VW ID. Buzz (MIB4, 1920×840). It shows Google Maps as an OEM-style Home with a
custom launcher, streams that screen to the car as CarPlay video, and feeds Android Auto turn-by-turn to the instrument cluster.

**Running now (2026-11-06):** image FINAL3 R2 on slot `_b` (super expanded SHA `5cac1165…`), post-boot verified 74/74,
plus launcher v21b (`c01562bc…`) as an app update. Test plan A–G passed in the car; **project closed by the owner**.
Fixes from here ship as app updates; a new image only for critical Android fixes. See
`docs/status/STATUS_AND_ROADMAP.md` and `docs/history/2026-11-01-to-06-final3.md`.

**Golden rules**
1. No OTA, ever. Changes ship as an image flashed via EDL (`OTA_POLICY_AND_ROLLBACK.md`).
2. EDL is the only guaranteed lifeline (`EDL_RECOVERY_RUNBOOK.md`). Read-only diagnose before any write.
3. Hash-check every script copied phone → PC (MTP truncated one once).
4. Bench PASS ≠ car PASS (`FEATURE_STATUS_AND_ACCEPTANCE.tsv`).

**Where things are** (private storage, not in git)
| What | Path |
|---|---|
| Running image + writer | `Download/qfil/otto/OTTO_A17_FINAL3/` |
| Previous image (fallback) | `Download/qfil/otto/OTTO_A17_FINAL2/` |
| FINAL3 benchmark (videos, photos) | `Download/OTTO/OTTO_FINAL3_BENCHMARK_20261106/` |
| A13 original backup | `Download/OTTO_A17_PERMANENT_MIGRATION/01_BACKUPS/a13_super/` (gz `7c277039…`) |
| Slot _b firmware dump | `~/OTTO/OTA_BASE_B_20261025/` (27 images, verified) |
| Build inputs | `~/otto_final_build/{work,inputs}` |
| Rescue tool | `Download/qfil/otto/OTTO_RESCUE/` |
| Launcher source | GitHub `jespernyboele-dotcom/otto-femto-oempp-stage3` (PRIVATE), branch `otto-media-autoplay` (v21b = `d217b6e`) |
(`~` = `/data/data/com.termux/files/home`; GitHub CLI login lives there — run `gh` with that HOME.)

**Rebuild:** `BUILD_AND_REPRODUCE.md`. **Components:** `OTTO_COMPONENTS.tsv` (FINAL2 inventory, 25.10; FINAL3 deltas in `firmware/final3/CHANGED_FILES.txt`). **History:** `OTTO_RELEASE_TIMELINE.md`.
**What not to run:** OTA scripts, `wipe-userdata`, `recover_flash_super.sh` (untested), any writer whose hash you did not check.
