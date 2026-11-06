#!/system/bin/sh
# OTTO BOOT3 trin 1 (2026-10-18): boot-only tuning, each step only if its marker exists in /data/adb/otto/config:
#   boot_a1  no boot animation (debug.sf.nobootanimation=1, this boot only)
#   boot_a3  full CPU during boot: both clusters at max frequency, all big cores online (core_ctl min=max)
#   boot_a4  I/O during boot: read_ahead_kb 2048 on mmcblk0
# Original values are saved to /data/adb/otto/state/boot_fast.orig and restored at boot_completed by
# service.d/31-otto-boot-fast-restore.sh. Remove the markers to switch everything off.
C=/data/adb/otto/config; S=/data/adb/otto/state/boot_fast.orig; L=/data/adb/otto/logs/boot_fast.log
B=$(cut -c1-8 /proc/sys/kernel/random/boot_id); rm -f $S
P0=/sys/devices/system/cpu/cpufreq/policy0; P4=/sys/devices/system/cpu/cpufreq/policy4; CC4=/sys/devices/system/cpu/cpu4/core_ctl; Q=/sys/block/mmcblk0/queue
done=""
if [ -f $C/boot_a1 ]; then setprop debug.sf.nobootanimation 1; done="$done a1"; fi
if [ -f $C/boot_a3 ]; then
  echo "P0MIN=$(cat $P0/scaling_min_freq)" >> $S; echo "P4MIN=$(cat $P4/scaling_min_freq)" >> $S; echo "CC4MIN=$(cat $CC4/min_cpus)" >> $S
  cat $P0/scaling_max_freq > $P0/scaling_min_freq; cat $P4/scaling_max_freq > $P4/scaling_min_freq; cat $CC4/max_cpus > $CC4/min_cpus
  done="$done a3"
fi
if [ -f $C/boot_a4 ]; then echo "RA=$(cat $Q/read_ahead_kb)" >> $S; echo 2048 > $Q/read_ahead_kb; done="$done a4"; fi
echo "$(date '+%F %T') boot=$B applied=[$done] p0min=$(cat $P0/scaling_min_freq) p4min=$(cat $P4/scaling_min_freq) cc4min=$(cat $CC4/min_cpus) ra=$(cat $Q/read_ahead_kb)" >> $L
exit 0
