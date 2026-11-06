#!/system/bin/sh
# OTTO drive logger (root, background): every 60 s for N minutes, log temps, GPU load/clock, CPU clocks,
# Maps frame stats (gfxinfo is reset each minute), NAVI status and top 5 processes. Read-only except gfxinfo resets.
# Usage: nohup sh drive_log.sh [minutes] &   Output: /data/local/tmp/otto_drive_<date>.txt
N=${1:-40}; O=/data/local/tmp/otto_drive_$(date +%m%d_%H%M).txt
K=/sys/class/kgsl/kgsl-3d0; M=com.google.android.apps.maps
t(){ for z in /sys/class/thermal/thermal_zone*; do case $(cat $z/type) in gpu|xo-therm|cpuss-0|cpu-1-2) echo -n "$(cat $z/type)=$(($(cat $z/temp)/1000)) ";; esac; done; }
echo "== drive log $(date) minutes=$N" > $O
dumpsys gfxinfo $M reset >/dev/null
i=0; while [ $i -lt $N ]; do
  b=0; s=0; while [ $s -lt 60 ]; do b=$((b+$(tr -dc 0-9 < $K/gpu_busy_percentage))); sleep 1; s=$((s+1)); done
  g=$(dumpsys gfxinfo $M | grep -E "Total frames|Janky frames:|90th percentile:|99th percentile:" | grep -v gpu | sed 's/.*: //' | tr '\n' ' ')
  dumpsys gfxinfo $M reset >/dev/null
  echo "$(date +%T) $(t)gpu_busy=$((b/60))% gpuclk=$(($(cat $K/gpuclk)/1000000)) cpu=$(($(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)/1000))/$(($(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq)/1000)) maps[frames jank 90th 99th]=$g nav=$(grep -E '^N (STATUS|POSITION)' /data/adb/otto_navi/navi.log | tail -1 | cut -c1-60)" >> $O
  top -b -n 1 -m 5 | tail -5 | awk '{print "   ", $9"%", $12, $13}' >> $O
  i=$((i+1))
done
echo "== end $(date)" >> $O
