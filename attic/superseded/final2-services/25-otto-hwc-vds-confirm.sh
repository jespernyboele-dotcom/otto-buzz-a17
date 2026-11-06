#!/system/bin/sh
# OTTO A17 R19: companion of /data/adb/post-fs-data.d/11-otto-hwc-vds.sh. Once Android has booted, remove the
# "pending" marker so the next boot enables the composer virtual-display path again. Logs one line.
P=/data/adb/otto/state/hwc_vds_pending; L=/data/adb/otto/logs/hwc_vds.log
n=0
until [ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || [ $n -ge 300 ]; do /system/bin/sleep 2; n=$((n+1)); done
[ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || exit 0
/system/bin/sleep 40
[ -f $P ] && /system/bin/rm -f $P
echo "$(/system/bin/date '+%F %T') boot=$(/system/bin/cat /proc/sys/kernel/random/boot_id) boot_completed vds=$(/system/bin/getprop debug.sf.enable_hwc_vds) isGpu=[$(/system/bin/dumpsys SurfaceFlinger --displays 2>/dev/null | /system/bin/grep -c 'isGpu=true')] pending_left=$([ -f $P ] && echo 1 || echo 0)" >> $L
exit 0
