#!/system/bin/sh
# OTTO A17 R19 (v2): end the golden boot recorder (init service otto_bootrecorder) once Android has booted, then
# keep its small log partition usable on the dash-cam principle (operator decisions 2026-10-11):
#   1. sys.boot_completed=1 + 20 s -> `stop otto_bootrecorder` (recorder, its init_boot rc and early start unchanged;
#      it writes O_DSYNC and syncs every second, so nothing durable is lost; "disabled oneshot" = no restart).
#   2. every boot log on /debug_ramdisk/otto_logfs is copied to /data/adb/otto/bootlogs/NNNNNN_<name> (size-checked),
#      the archive keeps the 15 newest (by sequence number, not by clock), older ones are removed.
#   3. logs that are safely archived are removed from the small partition, except the log of the current boot,
#      so the next boot always has room for a full recording. A log is never removed unless its archive copy
#      has the same size.
# Opt-out of everything: create /data/adb/otto/config/bootrecorder_keep_running
# Opt-out of 2+3 only:   create /data/adb/otto/config/bootrecorder_no_rotate
# Rollback: delete this file (takes effect at next boot).
PATH=/system/bin
O=/data/adb/otto; L=$O/logs/bootrecorder_stop.log; T=/debug_ramdisk/otto_logfs; A=$O/bootlogs; KEEP=15
[ -f $O/config/bootrecorder_keep_running ] && exit 0
n=0
until [ "$(getprop sys.boot_completed)" = "1" ] || [ $n -ge 300 ]; do sleep 2; n=$((n+1)); done
[ "$(getprop sys.boot_completed)" = "1" ] || exit 0
sleep 20
p=$(pidof otto_bootrecorder)
stop otto_bootrecorder
sleep 2
B=$(cat /proc/sys/kernel/random/boot_id)
msg="$(date '+%F %T') boot=$B up=$(cut -d' ' -f1 /proc/uptime) pid_before=[$p] svc=$(getprop init.svc.otto_bootrecorder) pid_after=[$(pidof otto_bootrecorder)]"
arch=0; rm_fs=0; rm_ar=0; rot=skipped
if [ ! -f $O/config/bootrecorder_no_rotate ] && [ -z "$(pidof otto_bootrecorder)" ] && grep -q " $T vfat " /proc/mounts && [ "$(realpath $T)" = "$T" ]; then
  rot=ok
  mkdir -p $A && chmod 700 $A
  cur=$(echo "$B" | tr -d '-' | cut -c1-11)
  seq=0; [ -f $A/.seq ] && read -r seq < $A/.seq; case "$seq" in ''|*[!0-9]*) seq=0;; esac
  # the current boot's log is handled last so that it gets the newest sequence number
  for f in $(ls $T | grep -v "^OTTO_R1A_$cur.LOG$") OTTO_R1A_$cur.LOG; do
    case "$f" in OTTO_R1A_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].LOG) ;; *) continue;; esac
    [ -f "$T/$f" ] && [ ! -L "$T/$f" ] || continue
    s=$(stat -c %s "$T/$f")
    have=
    for g in $(ls $A); do case "$g" in [0-9][0-9][0-9][0-9][0-9][0-9]_$f) [ "$(stat -c %s "$A/$g")" = "$s" ] && have=$g;; esac; done
    if [ -z "$have" ] && [ "$s" -gt 0 ]; then
      seq=$((seq+1)); g=$(printf '%06d' $seq)_$f
      cp "$T/$f" "$A/$g" && sync && [ "$(stat -c %s "$A/$g")" = "$s" ] && { have=$g; arch=$((arch+1)); echo $seq > $A/.seq; }
    fi
    # remove from the small partition only when archived (or empty), and never the current boot's log
    if [ "$f" != "OTTO_R1A_$cur.LOG" ] && { [ -n "$have" ] || [ "$s" = 0 ]; }; then rm -f "$T/$f" && rm_fs=$((rm_fs+1)); fi
  done
  c=0
  for g in $(ls -r $A); do
    case "$g" in [0-9][0-9][0-9][0-9][0-9][0-9]_OTTO_R1A_*.LOG) ;; *) continue;; esac
    c=$((c+1)); [ $c -gt $KEEP ] && [ -f "$A/$g" ] && [ ! -L "$A/$g" ] && rm -f "$A/$g" && rm_ar=$((rm_ar+1))
  done
  sync
fi
echo "$msg rotate=$rot archived=$arch removed_from_logfs=$rm_fs removed_from_archive=$rm_ar logfs_free_kb=$(df -k $T | tail -1 | awk '{print $4}') archive_files=$(ls $A 2>/dev/null | grep -c LOG)" >> $L
exit 0
