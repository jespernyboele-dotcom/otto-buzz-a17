# Status and roadmap (updated 2026-11-06)

## Running now — project closed
FINAL3 R2 on slot `_b` (expanded `5cac1165…`), flashed via EDL, post-boot verified 74/74, plus launcher **v21b**
(`c01562bc…`) as an app update. Test plan A–G passed in the car on 2026-11-06; owner: "vi er i mål".
Details: `docs/history/2026-11-01-to-06-final3.md`, report `evidence/2026-11-06-final3-benchmark/RAPPORT_FINAL3_BENCHMARK.txt`.

**Change policy from FINAL3:** fixes ship as app updates (`adb install -r`). A new image only for a critical
Android/system fix, and only after the owner says yes. Freeze: no new features; only CarPlay, GPS or boot breakers.

## Accepted in the car (2026-11-06)
CarPlay picture + audio at ~59.7 fps on the MIB4 panel (99.5 % of source pictures), steering-wheel keys incl. voice key,
car GPS into Android with Maps navigation following ("Searching for GPS" fixed by satellite extras), NAVI on the
cluster, fast Home switch (v21b), boot logo fading into a ready Home.

## Parked (owner decision, not planned)
1. VDS recreate (`attic/failed-or-parked/vds-recreate/`): 56 → 59 encoder fps on boots with a GPU-composed display.
2. Fixed left dock: first design (two cutout segments) gave a black screen; needs a new design. Dock stays fixed.
3. Recorder R9 intra-refresh: built, not deployed.
4. Rare smear from the Ottocast `libiDevice` queue: accepted; `tooling/diagnostics/smearwatch.sh` if it returns.
5. A13 restore path: never tested; EDL variant not built (EDL_RECOVERY_RUNBOOK §4).
6. Sources not located: audio bridge, ID. Buzz splash, video-only-while-parked logic.

## Deferred / separate
- Game box (WiiMoteCast, DolphinBar, Wii Remote): separate subproject; L2CAP blocker on A17 per mission text.
- GPU driver update (Adreno 610 V@0615.58, Dec 2022): only if a measured GPU bottleneck appears.

## Closed / rejected
- Pinch-zoom in CarPlay — impossible: the VW HU declares a one-finger touch screen.
- Boot animation in the car — not visible by design (projection mirrors windows only, starts after boot).
- Swipe dock — rejected by the owner; one fixed dock everywhere.
- F11 `ly_link.sh` supervisor — dropped (untestable).
- OTA updates (P0 incident) — rejected permanently.
- QIL write path — superseded by R119 Python writer.
- MapsMod (Vector/Zygisk) — replaced by launcher safe zone (v6).
- Podimo host — removed from build.
- Magisk modules — all baked into the image; FINAL3 has no `/data` test hooks (V55).
