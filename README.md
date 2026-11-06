# otto-platform

Platform side of **OTTO**: an Ottocast P3 Pro (Qualcomm SM6225, eMMC) running an Android 17 GSI with the OEM CarPlay chain
kept, in a VW ID. Buzz (MIB4, 1920×840). The launcher lives in its own repository (`otto-femto-oempp-stage3`).

**Start with [START_HERE.md](START_HERE.md).** Want to do something similar on your own device? **[guides/](guides/)**:
root over EDL, rescue, Android 17 with OEM CarPlay, 60 fps projection, car GPS for Maps, camera fps test, safe zone, lessons learned, Maps turn-by-turn to the cluster.

The repository is split by what a file **is**, so running code, results and dead ends never mix:

| Folder | Content |
|---|---|
| `src/` | **What runs on OTTO now** (FINAL3 R2): boot scripts, first boot, recorder R8, OEM no-reboot patches, NAVI, car GPS. Checked byte-for-byte against the image (`src/README.md`) |
| `firmware/` | Image build scripts (FINAL, FINAL2, FINAL3), the FINAL3 build record (`firmware/final3/`), SELinux, init `.rc`, overlay sources |
| `tooling/` | EDL writers per image (`edl/final`, `final2`, `final3`), rescue tool, root reference scripts, migration, diagnostics, maintenance |
| `tests/` | Tools that test: post-boot check (74), drive/car logging, fps chain, parked GPS feed, camera fps test |
| `evidence/` | **Measured results only**, one folder per session (FINAL3 benchmark, GPS "Searching" drive) |
| `attic/` | **Not running**: `superseded/` (older versions) and `failed-or-parked/` (tried, not used), each with why (`attic/README.md`) |
| `incidents/` | 2026-10-25 OTA incident: report and the OTA code, kept as history only |
| `guides/` | Standalone how-tos for others |
| `docs/`, `manifests/` | Status, history, recovery, build, security docs; component register (FINAL2 inventory), acceptance matrix, hashes |

> **Warning.** The tools under `tooling/` write partitions on a real device and can brick it or erase data. Nothing runs
> automatically; every write asks for a typed confirmation. Read `docs/recovery/EDL_RECOVERY_RUNBOOK.md` first.

Firmware images, OEM binaries, Google apps, the Firehose programmer and all keys are **not** in this repository
(see `docs/security/THIRD_PARTY_AND_SECRETS_REVIEW.md`); `manifests/` holds their hashes and locations.
