#!/system/bin/sh
# OTTO A17 R19: make the accepted performance baseline boot-persistent (operator decision 2026-10-11):
#   1. GPU floor 465 MHz: /sys/class/kgsl/kgsl-3d0/min_pwrlevel = 4 (written only if power level 4 really is 465 MHz).
#   2. A3a: SurfaceFlinger and display-composer threads that sit in cpuset /system-background are moved to /foreground
#      and bound to cpu4-7. Same logic as the proven /data/local/tmp/otto_b/a3a_place_sfhwc.sh.
# Runs once after boot (no loop). If SurfaceFlinger restarts later, A3a is lost until the next boot or a manual run.
# Manual:   sh 24-otto-a3a-gpu465.sh apply | rollback
# Opt-out without deleting: create /data/adb/otto/config/a3a_gpu465_off
# Rollback: delete this file (next boot), or run it with `rollback` for immediate effect (GPU floor back to level 5 = 320 MHz).
PATH=/system/bin
K=/sys/class/kgsl/kgsl-3d0; O=/data/adb/otto; L=$O/logs/a3a_gpu465.log; M=$O/state/a3a_moved.txt
NAMES="surfaceflinger vendor.qti.hardware.display.composer-service"
apply() {
  g=skipped
  set -- $(cat $K/gpu_available_frequencies 2>/dev/null)
  if [ "$5" = 465000000 ] && [ "$6" = 320000000 ]; then echo 4 > $K/min_pwrlevel; g=$(cat $K/min_pwrlevel); fi
  : > $M; n=0
  for nm in $NAMES; do p=$(pidof $nm); [ -n "$p" ] || continue
    for t in $(ls /proc/$p/task); do
      if [ "$(cat /proc/$p/task/$t/cpuset 2>/dev/null)" = /system-background ]; then
        echo $t > /dev/cpuset/foreground/tasks && taskset -p f0 $t >/dev/null 2>&1 && { echo "$p $t" >> $M; n=$((n+1)); }
      fi
    done
  done
  echo "$(date '+%F %T') boot=$(cat /proc/sys/kernel/random/boot_id) apply min_pwrlevel=$g a3a_moved=$n sf_cpuset=$(cat /proc/$(pidof surfaceflinger)/cpuset)" >> $L
}
rollback() {
  n=0
  for nm in $NAMES; do p=$(pidof $nm); [ -n "$p" ] || continue
    for t in $(ls /proc/$p/task); do
      if [ "$(cat /proc/$p/task/$t/cpuset 2>/dev/null)" = /foreground ]; then taskset -p ff $t >/dev/null 2>&1; echo $t > /dev/cpuset/system-background/tasks && n=$((n+1)); fi
    done
  done
  echo 5 > $K/min_pwrlevel
  echo "$(date '+%F %T') boot=$(cat /proc/sys/kernel/random/boot_id) rollback min_pwrlevel=$(cat $K/min_pwrlevel) a3a_restored=$n" >> $L
}
mkdir -p $O/logs $O/state $O/config 2>/dev/null
case "$1" in apply) apply; exit 0;; rollback) rollback; exit 0;; esac
[ -f $O/config/a3a_gpu465_off ] && exit 0
n=0
until [ "$(getprop sys.boot_completed)" = "1" ] || [ $n -ge 300 ]; do sleep 2; n=$((n+1)); done
[ "$(getprop sys.boot_completed)" = "1" ] || exit 0
sleep 30
apply
exit 0
