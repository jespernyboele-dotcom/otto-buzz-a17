#!/system/bin/sh
# OTTO A17 R19: keep the Wi-Fi firmware debug logger (init service vendor.cnss_diag) stopped after every boot.
# Operator approval 2026-10-11. It is a diagnostics-only logger (wrote ~2.4 GB/h to /data/vendor/wifi/wlan_logs).
# Touches ONLY vendor.cnss_diag. cnss-daemon, the WLAN driver, firmware and Wi-Fi config are not touched.
# Opt-out without deleting: create /data/adb/otto/config/cnss_diag_keep_enabled
# Rollback: delete this file (next boot starts the logger again); `start vendor.cnss_diag` restarts it at once.
L=/data/adb/otto/logs/cnss_diag_off.log
[ -f /data/adb/otto/config/cnss_diag_keep_enabled ] && exit 0
n=0
until [ "$(/system/bin/getprop init.svc.vendor.cnss_diag)" = "running" ] || [ $n -ge 60 ]; do /system/bin/sleep 2; n=$((n+1)); done
/system/bin/stop vendor.cnss_diag
n=0
until [ "$(/system/bin/getprop sys.boot_completed)" = "1" ] || [ $n -ge 120 ]; do /system/bin/sleep 2; n=$((n+1)); done
/system/bin/sleep 25
r=0
[ "$(/system/bin/getprop init.svc.vendor.cnss_diag)" = "running" ] && { /system/bin/stop vendor.cnss_diag; r=1; /system/bin/sleep 2; }
echo "$(/system/bin/date '+%F %T') boot=$(/system/bin/cat /proc/sys/kernel/random/boot_id) svc=$(/system/bin/getprop init.svc.vendor.cnss_diag) pid=[$(/system/bin/pidof cnss_diag)] second_stop=$r" >> $L
exit 0
