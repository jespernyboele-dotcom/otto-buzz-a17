# Candidates for the last A17 build (2026-10-31)

> History. This table was `src/final-candidates/README.md`; the folders it names moved on 2026-11-06:
> what is in FINAL3 to `src/` and `firmware/final3/`, the rest to `attic/` (see `attic/README.md`).

Nothing here is in an image yet. Each candidate was tested on the running FINAL2 through sha-guarded, reversible
`/data/adb/post-fs-data.d` bind mounts. The owner's rule: the final image is built only when everything remaining is
settled, and flashed via EDL. Evidence: `docs/history/2026-10-31-chain-test-and-final-prep.md`.

| # | What | Here | Built sha256 (reproducible) |
|---|---|---|---|
| F1 | Recorder R5: first synthetic AU after a real AU at 25 ms (was 16.667 ms) | `recorder5/` | `99631980…` |
| F2 | Bitrate 12 Mbit/s (owner's choice) | `/data/adb/otto/config/recorder_bitrate` | – |
| F3 | HWC-VDS confirmed at boot_completed + 10 s if SurfaceFlinger did not restart | `boot/service.d/25-otto-hwc-vds-confirm.sh` | – |
| F4 | `run.sh`: service.d scripts in parallel, 20 → 24 kept in order | `boot/run.sh` | – |
| F5 | Recorder R6 = R5 + up to 5 scrcpy starts in the first 90 s (was 2) | `recorder6/` | `a6be9a5a…` |
| F6 | `otto_cargps`: fresh by arrival when the wall clock is unset | `cargps/OttoCarGps.java` | dex `0fa22604…`, jar `7cff7445…` |
| F7 | `otto_cargps`: set the system clock from the car's GPS UTC when it is > 1 h off | same | same |
| F8 | Recorder R7 = R6 + H.264 High profile + idle colour-matrix keep-alive | `recorder7/` | `c6350313…` |
| F10 | `lylinkservice` binary patch: 7× `reboot()` + `sys.powerctl=reboot,recovery` → `mvn r0,#0` (source `1c6dd8c0…`) | `lylink-noreboot/patch_lylinkservice.py` | `9b3b76b5…` |
| F10b | `lyscrservice` binary patch: `CScreenServer::doReboot` tail call → `bx lr` (source `a4e67088…`) | `lylink-noreboot/patch_lyscrservice.py` | `8c727747…` |
| F11 | ~~`ly_link.sh` supervisor~~ **DROPPED 2026-11-01 (owner): untestable; FINAL2's `ly_link.sh` stays** | – | – |
| F13 | Stop `vendor.atfwd` (no modem function) | `boot/init/otto_final_f13.rc` | – |
| F14 | A3A GPU 465 applied at BOOT_COMPLETED, +60 s, and again on SurfaceFlinger pid change | `boot/service.d/24-otto-a3a-gpu465.sh` | – |
| F22 | Recorder R8 = R7 + encoder QP bounds 25–40 (as the OEM A13 recorder; `/data/adb/otto/config/recorder_qp`) | `recorder8/` | `fa8c668f…` |
| F23 | Background diet: disable no-function apps (Gmail, Drive, Contacts, Dialer, Google TV, …); video apps get no background | `boot/system_bin/otto_firstboot.sh`, `f23/f23_background_diet.sh` | – |

Build notes:
- `recorder*/build_r*.sh` link against OTTO's own 32-bit `libc.so` (`/apex/com.android.runtime/lib/bionic/libc.so`, sha `928f970b…`) and `liblog.so` (`/system/lib/liblog.so`, sha `171307b2…`). Copy them read-only into `devlibs/`; binaries are not in git.
- The historical R3 binary (`6b38d2df…`) cannot be rebuilt bit-exactly. R5 is the new reproducible baseline (same source, plus one line).
- `cargps/build_cargps.sh`: `javac --release 8` + Termux `d8 --release --min-api 26`. This reproduces the running FINAL2 `classes.dex` (`437cece7…`) bit-exactly from `src/navi/cargps/OttoCarGps.java`.
- `boot/91-otto-final-test.sh` is the test hook that bind-mounted F3, F4, F6 and F7. `recorder7/90-otto-rec-test.sh` is the recorder hook, an allow-list of R3–R7.

Session 2026-11-01:
- F4 `run.sh` now runs service.d scripts fully in parallel. The 20 → 24 ordering is dropped; 24 is self-timed on BOOT_COMPLETED.
- `boot/91-otto-final-test.sh` + `boot/table.txt`: the table-driven test hook (file, sha, target) that bind-mounted F3–F7, F10, F10b, F11 and F14.
- Measured live and closed without change: F12 (`sync` every 5 s costs 0 IO pressure), F20 (YUVPlaneInfo errors are gone), F21 (6 duplicate vsyncs, at startup only). F23 measured: +315 MB MemAvailable, CPU PSI 20 % → 7.6 %.
- Patched binaries and recorder `.so` files are not in git. Rebuild them with the scripts here and verify the sha256 values above.

## Landed: FINAL3 (2026-11-01 build, running since 2026-11-06)
F1–F8, F10, F10b, F13, F14, F22 (R8), F23 and the GPS satellites extras (`gps-satellites/`) are in FINAL3 R2:
`final3/` (build script, changed files, sums, flash guide, post-flash cleanup, post-boot verify 74/74, test plan).
Launcher v18 is in the image; v21b runs on top as an app update. History: `docs/history/2026-11-01-to-06-final3.md`.

Not in any image (owner decision, kept for reference):
| What | Here | State |
|---|---|---|
| Recorder R9: R8 + intra-refresh | `recorder9/` | codec accepts it; not deployed |
| Fixed left dock: `OttoDockLeft` RRO (cutout left + right) and `OttoSafeZone` v2 | `dock-left/` | **FAILED**: black screen on the car, rolled back. APKs not in git (`APK_SHA256SUMS.txt`) |
| VDS recreate: restart scrcpy once when its display is GPU-composed | `vds-recreate/93-otto-vds-recreate.sh` | proven manually (56 → 59 fps); paused by the owner |

Repo copies vs image inputs: `boot/system_bin/otto_firstboot.sh` is the FINAL3 input (`4fa81843…`, with section N,
12 Mbit/s) except one comment where the SSIDs are redacted; the build reads the unredacted staging copy.
`gps-satellites/OttoCarGps.java` is the source of the image jar `84d5e592…`.
