# attic — not running, kept on purpose

Nothing here is on OTTO. It is kept so the history and the lessons can be checked. Do not install from here.

## superseded/ — older versions of something that runs
| Folder | Replaced by | Why |
|---|---|---|
| `recorder/recorder2`, `recorder3` | `src/recorder` (R8) | R2: first A17 recorder; R3 added a bitrate file (8 Mbit/s, FINAL2) |
| `recorder/recorder5`–`recorder7` | R8 | steps: 25 ms synthetic frame, more scrcpy retries, High profile. R8 = R7 + QP 25–40 |
| `recorder/recorder8_test_hook` | R8 in `/system` | the `/data` bind-mount hook used to test R3–R8 live |
| `cargps/p5_final2` | `src/navi/cargps` | FINAL2 bridge (prediction, no clock fix, no satellites) |
| `cargps/f6_f7_no_satellites` | `src/navi/cargps` | fresh-by-arrival + clock from GPS, but no satellite extras: Maps said "Searching for GPS" |
| `final2-services/` | `src/boot`, `src/system-bin` | FINAL2 versions of firstboot, run.sh, 24, 25 |
| `final-flash-2026-10-24/` | – | one-time scripts around the FINAL flash (retire Magisk modules, clean up after) |
| `postboot-verify/` | `tests/acceptance/postboot_verify_device.sh` (74 checks) | FINAL2 version (58 checks), migration version (19.10) |
| `sepolicy-v1/` | `firmware/patches/sepolicy/` | v1 rules: 0 of their lines are in the FINAL3 system image; all lines of the current `otto_plat.cil` and `otto_property_contexts` are |
| `migration/preflight.sh.before_P49_fix` | `tooling/migration/scripts/preflight.sh` | before a fix in the migration preflight |
| `flash-guide-pre-final/` | `tooling/edl/final3/VEJLEDNING_FINAL3_FLASH.txt` | flash guide for the first A17 image (18.10) |
| `test-hooks/` | – | table-driven `/data` test hook (file, sha, target) that tested F3–F14 live before FINAL3. The method is in guide 08 |

## failed-or-parked/ — tried, not used
| Folder | State | What we learned |
|---|---|---|
| `dock-left/` | **FAILED** 2026-11-03 | a display cutout with two segments (left + right) gave a black car screen. Rolled back. One change per boot |
| `vds-recreate/` | parked (owner) | proven: re-creating a GPU-composed virtual display gives 59 instead of 56 fps. Not needed: the car showed 99.5 % |
| `recorder9/` | not used | R8 + intra-refresh: the codec accepts it; no need found |
| `spotify-warm/` | not used | Spotify warm-up after boot: tested, not installed |
| (no files) F11 `ly_link.sh` supervisor | dropped 2026-11-01 | could not be tested safely; FINAL2's `ly_link.sh` stays |
