#!/system/bin/sh
# OTTO VDS fix test (2026-11-06, from /data). A CarPlay session that starts early in boot can get a GPU-composed scrcpy
# virtual display (SurfaceFlinger isGpu=true): measured 56 encoded frames/s at 60 fps video instead of ~59 with the
# hardware (HWC) virtual display. Once VDS is confirmed, this checks every 30 s for an hour and, if the scrcpy display is
# GPU-composed, stops the scrcpy server once; the recorder starts a new one (~1 s still picture on the car), whose
# display HWC can now take. At most 3 times per boot. Undo: rm /data/adb/service.d/93-otto-vds-recreate.sh
L=/data/adb/otto/logs/vds_recreate.log; B=$(cut -c1-8 /proc/sys/kernel/random/boot_id); n=0; i=0
say() { echo "$(date '+%F %T') boot=$B up=$(cut -d' ' -f1 /proc/uptime) $*" >> $L; }
isgpu() { dumpsys SurfaceFlinger 2>/dev/null | grep -A8 'name="scrcpy"' | grep -m1 -o 'isGpu=[a-z]*'; }
say "start"
while [ $i -lt 120 ] && [ $n -lt 3 ]; do
  sleep 30; i=$((i+1))
  grep -q "boot=$B" /data/adb/otto/logs/hwc_vds.log 2>/dev/null || continue
  g=$(isgpu); [ "$g" = "isGpu=true" ] || continue
  p=$(ps -A -o PID,ARGS | grep '[c]om.genymobile.scrcpy' | awk '{print $1}' | head -1); [ -n "$p" ] || continue
  n=$((n+1)); say "scrcpy display is GPU-composed: stopping scrcpy pid=$p (#$n)"
  kill $p; sleep 8; say "after: $(isgpu)"
done
say "end checks=$i recreations=$n final=$(isgpu)"
