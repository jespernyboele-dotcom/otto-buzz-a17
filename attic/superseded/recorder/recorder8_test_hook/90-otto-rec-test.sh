#!/system/bin/sh
# OTTO Recorder R3 test (2026-10-25), extended 2026-10-31 for the R4 cadence test. Magisk post-fs-data.d: runs before
# ly_link starts lyscrservice. Bind-mounts the test libscreenrecord.so over /system/lib for this boot only; nothing on
# /system is written. Accepted builds: R3 6b38d2df (original), R4 26647c86 (R3 with the first synthetic-frame deadline
# after a real frame at 25 ms instead of 16.667 ms, 2-byte patch), R5 99631980 (same change built from source), R6 a6be9a5a (R5 + early-boot scrcpy retries), R7 c6350313 (R6 + High profile experiment), R7d 9b0fee02 (R7 + test-only stream dump), R8 fa8c668f (R7 + OEM QP bounds). Undo: restore 90-otto-rec-test.sh.r3bak and
# libscreenrecord_r3_6b38d2df.so from /data/adb/otto/rec_test/ and reboot.
L=/data/adb/otto/rec_test/libscreenrecord.so
mkdir -p /data/adb/otto/logs
s=$(sha256sum $L 2>/dev/null | cut -d' ' -f1)
case "$s" in
  6b38d2dfe5c6ff63a350f6c79d2c826fe5af6e4d1eb866e2239331932c2903c0|26647c860c463c4275af9466323017a5d4336d362de3b3078de7bfad675840a0|996319800b14a2ff453cf635a27b041e728bf47552d05a2053f756bca5729ece|a6be9a5a504d3060bd24b7ee79c2cfb7297bc02ad54b1f2422d02764cecfae2c|c63503134f0dc408e37ff49b2f29465dea27542d212b891f30245d389654f8d3|9b0fee0281ee8d53a4db3e6ab47eb344bf337d422ea70e643f088085ba0d8833|fa8c668f0daf13dd8ceaa9c2e6f2465943ace64e8398014c58b476101a47d4a4)
    mount -o bind $L /system/lib/libscreenrecord.so && r="bound ${s%%${s#????????}}" || r=mount-failed ;;
  *) r=skipped-lib-missing-or-sha-mismatch ;;
esac
echo "$(date '+%F %T') $r bitrate_file=$(cat /data/adb/otto/config/recorder_bitrate 2>/dev/null)" >> /data/adb/otto/logs/rec_test.log
