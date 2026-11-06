#!/system/bin/sh
# OTTO A17: keep logical display 2 (the 1280x720 mirror output) disabled after every boot.
# Operator request 2026-10-11. Uses the same command as the operator's proven R12 script.
# Opt-out without deleting: create /data/adb/otto/config/display2_keep_enabled
# Rollback: delete this file (takes effect at next boot); `cmd display enable-display 2` re-enables at once.
L=/data/adb/otto/logs/display2_off.log
[ -f /data/adb/otto/config/display2_keep_enabled ] && exit 0
n=0
until [ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || [ $n -ge 120 ]; do /system/bin/sleep 2; n=$((n+1)); done
/system/bin/sleep 20
i=0; rc=; ids=
while [ $i -lt 5 ]; do
  /system/bin/cmd display disable-display 2 >/dev/null 2>&1; rc=$?
  /system/bin/sleep 3
  ids=$(/system/bin/cmd display get-displays -i 2>/dev/null | /system/bin/tr '\n' ' ')
  case " $ids " in *" 2 "*) i=$((i+1));; *) break;; esac
done
echo "$(/system/bin/date '+%F %T') boot=$(/system/bin/cat /proc/sys/kernel/random/boot_id) rc=$rc retries=$i active_ids=[$ids]" >> $L
exit 0
