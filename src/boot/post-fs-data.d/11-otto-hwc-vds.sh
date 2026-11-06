#!/system/bin/sh
# OTTO A17 R19 (post-fs-data stage, before SurfaceFlinger starts): route virtual displays through the vendor display
# composer (debug.sf.enable_hwc_vds=1), as the Android 13 vendor configuration intends. The CarPlay recorder then
# delivers NV12 to the video encoder and the encoder's per-frame RGBA->NV12 conversion disappears.
# Fail-safe: a "pending" marker is written before the property is set and is removed by
# /data/adb/service.d/25-otto-hwc-vds-confirm.sh once the boot has completed. If a boot does not complete, the marker
# is still there at the next boot and this script then does NOTHING (normal GPU virtual display) and records it.
# Opt-out without deleting: create /data/adb/otto/config/hwc_vds_off
# Rollback: delete this file and reboot.
C=/data/adb/otto/config; L=/data/adb/otto/logs/hwc_vds.log; P=/data/adb/otto/state/hwc_vds_pending
[ -f $C/hwc_vds_off ] && exit 0
if [ -f $P ]; then
  echo "boot=$(cat /proc/sys/kernel/random/boot_id) SKIPPED: previous boot with hwc_vds did not complete; remove $P to re-enable" >> $L
  exit 0
fi
echo 1 > $P
sync
setprop debug.sf.enable_hwc_vds 1
echo "boot=$(cat /proc/sys/kernel/random/boot_id) set debug.sf.enable_hwc_vds=$(getprop debug.sf.enable_hwc_vds)" >> $L
exit 0
