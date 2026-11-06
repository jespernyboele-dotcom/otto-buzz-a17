#!/system/bin/sh
# OTTO A17 R19: stop two Android-13 vendor daemons that cannot run on Android 17 and crash-restart every ~5 s:
#   vendor.atfwd (ATFWD-daemon, modem AT forwarding) and wfdhdcphalservice (Miracast HDCP).
# Cause: their own minijail seccomp policies do not allow gettid. Operator approval 2026-10-11. seccomp is not touched.
# Opt-out without deleting: create /data/adb/otto/config/vendor_crashloops_keep
# Rollback: delete this file (next boot); `start vendor.atfwd; start wfdhdcphalservice` at once.
L=/data/adb/otto/logs/vendor_crashloops_off.log
[ -f /data/adb/otto/config/vendor_crashloops_keep ] && exit 0
n=0
until [ -n "$(/system/bin/getprop init.svc.vendor.atfwd)" ] || [ $n -ge 60 ]; do /system/bin/sleep 2; n=$((n+1)); done
/system/bin/stop vendor.atfwd
n=0
until [ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || [ $n -ge 120 ]; do /system/bin/sleep 2; n=$((n+1)); done
/system/bin/sleep 25
r=0
for s in vendor.atfwd; do [ "$(/system/bin/getprop init.svc.$s)" = "stopped" ] || { /system/bin/stop $s; r=$((r+1)); }; done
/system/bin/sleep 2
echo "$(/system/bin/date '+%F %T') boot=$(/system/bin/cat /proc/sys/kernel/random/boot_id) atfwd=$(/system/bin/getprop init.svc.vendor.atfwd) wfdhdcp=$(/system/bin/getprop init.svc.wfdhdcphalservice) second_stop=$r" >> $L
exit 0
