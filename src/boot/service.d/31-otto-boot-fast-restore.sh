#!/system/bin/sh
# OTTO BOOT3: restores the values saved by post-fs-data.d/31-otto-boot-fast.sh once boot has completed.
S=/data/adb/otto/state/boot_fast.orig; L=/data/adb/otto/logs/boot_fast.log
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
[ -f $S ] || exit 0
. $S
P0=/sys/devices/system/cpu/cpufreq/policy0; P4=/sys/devices/system/cpu/cpufreq/policy4; CC4=/sys/devices/system/cpu/cpu4/core_ctl; Q=/sys/block/mmcblk0/queue
[ -n "$P0MIN" ] && echo $P0MIN > $P0/scaling_min_freq
[ -n "$P4MIN" ] && echo $P4MIN > $P4/scaling_min_freq
[ -n "$CC4MIN" ] && echo $CC4MIN > $CC4/min_cpus
[ -n "$RA" ] && echo $RA > $Q/read_ahead_kb
echo "$(date '+%F %T') boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) restored p0min=$(cat $P0/scaling_min_freq) p4min=$(cat $P4/scaling_min_freq) cc4min=$(cat $CC4/min_cpus) ra=$(cat $Q/read_ahead_kb)" >> $L
rm -f $S
exit 0
