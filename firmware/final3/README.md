# FINAL3 R2 — build record (running since 2026-11-06)

Built 2026-11-01 by `../build/otto_final3_build.py` on FINAL2's super (inputs sha-guarded; it imports `otto_final_build.py`).
- `CHANGED_FILES.txt`: the 11 differences to FINAL2, all in `system_b` (the list is printed twice by the build; same content).
- `SHA256SUMS.txt`: simg `5c508051…`, expanded `5cac1165…`, and each partition image. `BUILD_LOG.txt`: the build run.
- `TESTPLAN_FINAL3.txt`: test plan A–G; results in `../../evidence/2026-11-06-final3-benchmark/`.
- `post_flash_cleanup_final3.sh`: removes the `/data` test files of the candidate phase after the flash.
- Flash: `../../tooling/edl/final3/` (writer `b7aee127…` + guide). Post-boot check: `../../tests/acceptance/postboot_verify_device.sh`.
