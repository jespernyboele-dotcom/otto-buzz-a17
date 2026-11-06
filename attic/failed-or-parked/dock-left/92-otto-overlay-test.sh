#!/system/bin/sh
# OTTO overlay test (2026-11-03): the fixed left dock. Magisk post-fs-data.d: bind-mounts a copy of /system/product/overlay
# with OttoDockLeft.apk (new) and OttoSafeZone.apk v2 (left strip + right Home zone) for this boot only. Nothing on /system
# is written. Both APKs are sha-guarded; if either does not match, nothing is mounted.
# Undo: rm /data/adb/post-fs-data.d/92-otto-overlay-test.sh and reboot.
D=/data/adb/otto/overlay_test; L=/data/adb/otto/logs/overlay_test.log
s1=$(sha256sum $D/OttoDockLeft.apk 2>/dev/null | cut -d' ' -f1); s2=$(sha256sum $D/OttoSafeZone.apk 2>/dev/null | cut -d' ' -f1)
if [ "$s1" = e94695a2e67b8bd32b038eae6cbe9aa7cfe12f0a7955e61936faa4ef7bc2a931 ] && [ "$s2" = ff1c8d555d69389654363e07fdf70ab35e9c9b68f6b044db745daa7fe3285bd7 ]; then
  chcon -R u:object_r:system_file:s0 $D
  mount -o bind $D /system/product/overlay && r=bound || r=mount-failed
else
  r="skipped (sha)"
fi
mkdir -p /data/adb/otto/logs; echo "$(date '+%F %T') boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) overlay_test=$r" >> $L
