# Build and reproduce

## Image (super) — FINAL2
Host: Android phone, Termux (native, not proot): Python 3.14.6, e2fsprogs 1.47.4 (debugfs, e2fsck, resize2fs),
android-tools lpmake/lpunpack/lpdump/img2simg (Termux package; version string not printed), avbtool 1.4.0.
Disk: ~18 GB free during a build.

Inputs (private, never in git):
- `~/otto_final_build/work/{odm,system,system_dlkm,vendor,vendor_dlkm}_b.final.img` — FINAL images; sha-checked against
  `OTTO_A17_FINAL/SHA256SUMS.txt` by the build.
- `~/otto_final_build/inputs/` (Magisk-module payloads, third-party APKs), `release_apks/…` (own signed launcher builds).
- FINAL itself came from `~/otto_mig_work/super_parts/*.img` (= the running OTTO of 24.10; vendor_b with shared_blocks removed).

Steps:
```
cd qfil/otto/final_build/build
python3 otto_final2_build.py      # → qfil/otto/OTTO_A17_FINAL2/
```
The script stops at the first error. It verifies: inputs = OTA1-intended files (sha prefixes), base images = flashed FINAL,
each written file read back (content, mode, uid/gid, SELinux label), e2fsck clean, other partitions unchanged, lpunpack
round-trip byte-identical, and writes BUILD_LOG, SHA256SUMS, lpdump and CHANGED_FILES (otto_diff_manifest.py).
Expected: raw `ce324a0714bde6773da3c14ab03dea3615bf37a1908ff49965cc8f0d8da764e6`.
FINAL3: `firmware/build/otto_final3_build.py` on FINAL2's super; expected raw `5cac116531d47d02…` (`final3/SHA256SUMS.txt`). Determinism of the simg hash across
runs: not tested (ext4 write order is deterministic with debugfs; timestamps in inode may differ — UNVERIFIED).

## Launcher
Repo `jespernyboele-dotcom/otto-femto-oempp-stage3` (PRIVATE). Running: v21b = `d217b6e` on branch `otto-media-autoplay`,
APK `c01562bc…` (CI run 42204986397), installed as an app update over FINAL3's v18 (`94109474…`).
Historical (FINAL2): branch `otto-perf-release`, v10 = `0935e476`.
Built and signed by GitHub Actions (`.github/workflows/otto-stage3-debug.yml`); signer SHA-256 `71c7eab8…`.
Release APK sha `d8c6382b…` (`release_apks/v10-connectfront/OTTO_SIGNED_BUILD_MANIFEST.txt`).
Local reproduction without the signing key gives a differently signed APK (functionally comparable, not byte-identical).

## Recorder 2.0 (`libscreenrecord.so`, 32-bit ARM)
Source `Download/OTTO/R20_RECORDER2/otto_screenrecord_a17_r2.c.txt`; artifact `libscreenrecord_a17_r2.so` = running
(`946f4f12…`). Toolchain: Termux/NDK cross compiler for `arm-linux-androideabi` (path string in the binary); exact
version and command line **not recorded** → reproducibility UNVERIFIED.

## NAVI
`NAV_FINAL_ARCH_R1/V06_RELEASE_PREP_20261017/{src,build,V06_SHA256SUMS.txt}` (otto_rgid.c, OttoAaNav.java, OttoAaConv.java)
and `00_MASTER_STATE/OTTO_NAVI_CAR_GPS_P5_SMOOTH_OFFLINE_20261016/{src,build,MANIFEST.sha256}` (OttoCarGps.java).
Running binaries equal those build outputs. Compiler versions: see the folders' reports (not re-read in this audit).

## What cannot be reproduced without private/proprietary material
GSI, OEM vendor/odm/dlkm, boot chain, Firehose programmer, OEM CarPlay binaries, Google apps, signing keys.
A third party can reproduce **the method** and the own components, not the image bytes.
