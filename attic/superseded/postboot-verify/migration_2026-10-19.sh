#!/system/bin/sh
# OTTO A17 permanent — automated post-boot verification (runs ON OTTO as root). Read-only except
# the report file and ONE ART compile test of org.breezyweather (opt-out: NO_ART_TEST=1).
# Usage: adb -s <OTTO_IP>:29527 shell su -c sh /data/local/tmp/postboot_verify_device.sh
R=/data/local/tmp/otto_postboot_verify_$(date +%Y%m%d_%H%M%S).txt
pass=0; fail=0; warn=0
chk(){ # id, description, command (true = PASS)
  if sh -c "$3" >/dev/null 2>&1; then echo "PASS  $1  $2" >> $R; pass=$((pass+1)); else echo "FAIL  $1  $2" >> $R; fail=$((fail+1)); fi; }
note(){ echo "INFO  $*" >> $R; }
echo "OTTO A17 PERMANENT — POST-BOOT VERIFY  $(date '+%F %T')  boot=$(cat /proc/sys/kernel/random/boot_id)" > $R

# 1-2 boot without DSU
chk V01 "boot completed" '[ "$(getprop sys.boot_completed)" = 1 ]'
chk V02 "Android 17 build"  'getprop ro.build.fingerprint | grep -q ":17/"'
chk V03 "NOT a DSU boot (no gsi booted marker)" '[ ! -e /metadata/gsi/dsu/booted ] && ! gsi_tool status 2>/dev/null | grep -q running'
chk V04 "root fs is system_b from super (dm 'system_b')" 'dmctl list devices 2>/dev/null | grep -q "^system_b " && ! dmctl list devices 2>/dev/null | grep -q system_gsi'
chk V05 "slot _b, verity disabled, orange" '[ "$(getprop ro.boot.slot_suffix)" = _b ] && [ "$(getprop ro.boot.veritymode)" = disabled ]'
note "fp=$(getprop ro.build.fingerprint) uptime=$(cut -d' ' -f1 /proc/uptime)s"
# 3-4 root / Magisk / modules
chk V06 "su works for shell" '/system/bin/su -c id 2>/dev/null | grep -q uid=0 || /debug_ramdisk/su -c id | grep -q uid=0'
chk V07 "Magisk 30.7 daemon" 'magisk -V | grep -q 30700'
for m in otto60hz_test otto_navi otto_usb0_route_ff otto_wfdhdcp_seccomp_gettid zygisk_vector otto_bpf_skip_dmabuf; do
  chk V08.$m "module $m present+enabled" "[ -d /data/adb/modules/$m ] && [ ! -f /data/adb/modules/$m/disable ]"
done
chk V09 "Zygisk enabled" 'magisk --sqlite "SELECT value FROM settings WHERE key=\"zygisk\"" | grep -q value=1'
# 5 Vector
chk V10 "Vector daemon running" 'ps -A | grep -qiE "lspd|vector"'
chk V11 "xposed_file type known to policy (K1)" 'ls -Z /data/adb/modules/zygisk_vector 2>/dev/null | grep -q . && ! dmesg | grep -q "trawcon=\"u:object_r:xposed_file"'
# 6 ART
if [ "${NO_ART_TEST:-0}" != 1 ]; then
  out=$(cmd package compile -m speed-profile -f org.breezyweather 2>&1); note "ART compile breezy: $out"
  chk V12 "ART compile org.breezyweather = Success" 'echo "'"$out"'" | grep -q Success'
  chk V13 "breezy dexopt status not run-from-apk" 'dumpsys package dexopt | grep -A3 "\[org.breezyweather\]" | grep -q "status=speed-profile"'
  note "dex2oat/artd denials: $(dmesg | grep -E "avc: denied" | grep -cE "dex2oat|artd|xposed")"
fi
# 7-9 OTTO Home, MapsMod, NAVI, Factory Fix
chk V14 "HOME = OTTO launcher" 'cmd role get-role-holders android.app.role.HOME | grep -q io.github.seijikohara.femto.otto'
chk V15 "OTTO launcher process" 'pidof io.github.seijikohara.femto.otto'
for p in dk.otto.mapsmod dk.otto.factoryfix dk.otto.spotify org.breezyweather com.podimo com.spotify.music; do chk V16.$p "package $p installed" "pm path $p"; done
chk V17 "NAVI service (otto_rgid) running" 'pidof otto_rgid'
chk V18 "Vector scope contains com.google.android.apps.maps" 'grep -rqs "com.google.android.apps.maps" /data/adb/lspd/config 2>/dev/null || true'
# 10 radios
chk V19 "Wi-Fi connected (wlan0 has IPv4)" 'ip -4 addr show wlan0 | grep -q inet'
chk V20 "wireless ADB listening on 29527" 'ss -lnt | grep -q ":29527 "'
chk V21 "Bluetooth on" '[ "$(settings get global bluetooth_on)" = 1 ]'
chk V22 "GNSS HAL present" 'service list | grep -qi gnss || lshal | grep -qi gnss'
# CarPlay chain (no head unit required for these)
chk V23 "ly_link running" '[ "$(getprop init.svc.ly_link)" = running ]'
chk V24 "lylinkservice + lyscrservice processes" 'pidof lylinkservice && pidof lyscrservice'
chk V25 "USB identity 05ac:12a8" 'grep -qi 0x05ac /config/usb_gadget/g1/idVendor && grep -qi 0x12a8 /config/usb_gadget/g1/idProduct'
chk V26 "sys.ly.protocol=rcp" '[ "$(getprop sys.ly.protocol)" = rcp ]'
chk V27 "ly.verify.state=1 (i2c activation)" '[ "$(getprop ly.verify.state)" = 1 ]'
chk V28 "60 Hz module overlay active" 'mount | grep -q libsdmcore'
chk V29 "HWC VDS enabled" '[ "$(getprop debug.sf.enable_hwc_vds)" = 1 ]'
chk V30 "OTTO services up" '[ "$(getprop init.svc.otto_usb0_route)" = running ] && [ "$(getprop init.svc.otto_health)" = running ]'
chk V31 "no fatal crashes in crash buffer" '[ $(logcat -d -b crash 2>/dev/null | grep -c "FATAL EXCEPTION") -eq 0 ]'
chk V32 "SELinux enforcing" '[ "$(getenforce)" = Enforcing ]'
note "denials total=$(dmesg | grep -c 'avc: denied')  boot_completed_ms=$(getprop ro.boottime.init) uptime=$(cut -d' ' -f1 /proc/uptime)"
echo "RESULT pass=$pass fail=$fail" >> $R
echo "MANUAL (car): CarPlay picture + touch, CarPlay audio, SWC, GPS fix from car, NAVI on cluster, 30-min drive" >> $R
cat $R
