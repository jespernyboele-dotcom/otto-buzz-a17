#!/system/bin/sh
# OTTO Recorder R3 test (2026-10-25). Magisk post-fs-data.d: runs before ly_link starts lyscrservice.
# Bind-mounts the test libscreenrecord.so over /system/lib for this boot only; nothing on /system is written.
# Undo: rm /data/adb/post-fs-data.d/90-otto-rec-test.sh and reboot.
L=/data/adb/otto/rec_test/libscreenrecord.so
mkdir -p /data/adb/otto/logs
if [ -f $L ] && [ "$(sha256sum $L | cut -d' ' -f1)" = "6b38d2dfe5c6ff63a350f6c79d2c826fe5af6e4d1eb866e2239331932c2903c0" ]; then
  mount -o bind $L /system/lib/libscreenrecord.so && r=bound || r=mount-failed
else
  r=skipped-lib-missing-or-sha-mismatch
fi
echo "$(date '+%F %T') $r bitrate_file=$(cat /data/adb/otto/config/recorder_bitrate 2>/dev/null)" >> /data/adb/otto/logs/rec_test.log
