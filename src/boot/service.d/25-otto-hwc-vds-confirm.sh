#!/system/bin/sh
# OTTO A17 R19, F3 2026-10-31: companion of post-fs-data.d/11-otto-hwc-vds.sh. Removes the "pending" marker once the boot
# with the composer virtual-display path is proven good, so the next boot enables it again. Logs one line.
# Proven good = sys.boot_completed + 10 s, and SurfaceFlinger has not restarted (a VDS fault would crash it when the
# CarPlay recorder creates its virtual display, ~22-26 s after power-on). FINAL2 waited boot_completed + 40 s behind the
# other service scripts (~190 s), so a short drive often turned VDS off for the next boot.
P=/data/adb/otto/state/hwc_vds_pending; L=/data/adb/otto/logs/hwc_vds.log
n=0
until [ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || [ $n -ge 300 ]; do /system/bin/sleep 2; n=$((n+1)); done
[ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || exit 0
/system/bin/sleep 10
sf=$(/system/bin/pidof surfaceflinger)
# start time of SurfaceFlinger in seconds after boot (field 22 of /proc/<pid>/stat, clock ticks of 100 Hz)
st=$([ -n "$sf" ] && /system/bin/awk '{print int($22/100)}' /proc/$sf/stat)
ok=0; [ -n "$st" ] && [ "$st" -lt 60 ] && ok=1
[ $ok = 1 ] && [ -f $P ] && /system/bin/rm -f $P
echo "$(/system/bin/date '+%F %T') boot=$(/system/bin/cat /proc/sys/kernel/random/boot_id) up=$(/system/bin/cut -d' ' -f1 /proc/uptime) boot_completed vds=$(/system/bin/getprop debug.sf.enable_hwc_vds) sf_start=${st}s confirm=$ok isGpu=[$(/system/bin/dumpsys SurfaceFlinger --displays 2>/dev/null | /system/bin/grep -c 'isGpu=true')] pending_left=$([ -f $P ] && echo 1 || echo 0)" >> $L
exit 0
