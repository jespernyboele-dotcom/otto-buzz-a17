#!/system/bin/sh
# OTTO A17 FINAL — automated post-boot verification (runs ON OTTO as root). Read-only except the
# report file and ONE ART compile test of org.breezyweather (opt-out: NO_ART_TEST=1).
# Usage: adb -s <OTTO_IP>:29527 shell su -c sh /data/local/tmp/postboot_verify_device.sh
# FINAL (2026-10-23): everything is baked into the image. Magisk stays for root only: no OTTO
# modules, no Zygisk, no Vector. FINAL2 (2026-10-25): no OTA any more.
R=/data/local/tmp/otto_postboot_verify_$(date +%Y%m%d_%H%M%S).txt
pass=0; fail=0
chk(){ # id, description, command (true = PASS)
  if sh -c "$3" >/dev/null 2>&1; then echo "PASS  $1  $2" >> $R; pass=$((pass+1)); else echo "FAIL  $1  $2" >> $R; fail=$((fail+1)); fi; }
note(){ echo "INFO  $*" >> $R; }
SLOT=$(getprop ro.boot.slot_suffix)
L=io.github.seijikohara.femto.otto
echo "OTTO A17 FINAL — POST-BOOT VERIFY  $(date '+%F %T')  boot=$(cat /proc/sys/kernel/random/boot_id)" > $R

# 1-2 boot from super, either slot (OTA)
chk V01 "boot completed" '[ "$(getprop sys.boot_completed)" = 1 ]'
chk V02 "Android 17 build" 'getprop ro.build.fingerprint | grep -q ":17/"'
chk V03 "NOT a DSU boot (no gsi booted marker)" '[ ! -e /metadata/gsi/dsu/booted ] && ! gsi_tool status 2>/dev/null | grep -q running'
chk V04 "root fs is system$SLOT from super" 'dmctl list devices 2>/dev/null | grep -q "^system'"$SLOT"' " && ! dmctl list devices 2>/dev/null | grep -q system_gsi'
chk V05 "verity disabled, orange (slot $SLOT)" '[ "$(getprop ro.boot.veritymode)" = disabled ] && [ "$(getprop ro.boot.verifiedbootstate)" = orange ]'
note "fp=$(getprop ro.build.fingerprint) slot=$SLOT uptime=$(cut -d' ' -f1 /proc/uptime)s"

# 3-4 root = Magisk only; nothing else hooks the system
chk V06 "su works for shell" '/system/bin/su -c id 2>/dev/null | grep -q uid=0 || /debug_ramdisk/su -c id | grep -q uid=0'
chk V07 "Magisk 30.7 daemon" 'magisk -V | grep -q 30700'
chk V08 "no Magisk modules (all baked into the image)" '[ -z "$(ls /data/adb/modules 2>/dev/null)" ]'
note "modules=[$(ls /data/adb/modules 2>/dev/null | tr '\n' ' ')]"
chk V09 "Zygisk off and not in zygote" 'magisk --sqlite "SELECT value FROM settings WHERE key=\"zygisk\"" | grep -qv value=1 && ! grep -q zygisk /proc/$(pidof zygote64)/maps'
chk V10 "no Vector/LSPosed daemon" '! ps -A | grep -qiE "lspd|vector"'

# 5 ART without the K1 Vector rules
if [ "${NO_ART_TEST:-0}" != 1 ]; then
  out=$(cmd package compile -m speed-profile -f org.breezyweather 2>&1); note "ART compile breezy: $out"
  chk V11 "ART compile org.breezyweather = Success" 'echo "'"$out"'" | grep -q Success'
  chk V12 "breezy dexopt status not run-from-apk" 'dumpsys package dexopt | grep -A3 "\[org.breezyweather\]" | grep -q "status=speed-profile"'
  chk V13 "0 dex2oat/artd denials" '[ $(dmesg | grep "avc: denied" | grep -cE "dex2oat|artd") -eq 0 ]'
fi

# 6 OTTO Home: launcher, dock, listeners, overlays (2-layer Home)
chk V14 "HOME = OTTO launcher" 'cmd role get-role-holders android.app.role.HOME | grep -q '"$L"
chk V15 "OTTO launcher process" 'pidof '"$L"
chk V16 "dock accessibility service on" 'settings get secure enabled_accessibility_services | grep -q OttoGlobalDockService'
chk V17 "music listener approved" 'cmd notification list-approved-listeners 2>/dev/null | grep -q MusicSessionListenerService || settings get secure enabled_notification_listeners | grep -q MusicSessionListenerService'
chk V18 "overlay: no status bar / no corners (OttoChrome)" 'cmd overlay list android | grep -q "\[x\] dk.otto.overlay.chrome"'
chk V19 "overlay: no privacy dot (OttoSystemUi)" 'cmd overlay list com.android.systemui | grep -q "\[x\] dk.otto.overlay.systemui"'
chk V20 "overlay: safe zone installed" 'cmd overlay list android | grep -q "dk.otto.overlay.safezone"'
chk V20b "Maps picture-in-picture off" 'appops get com.google.android.apps.maps PICTURE_IN_PICTURE | grep -q ignore'
for p in dk.otto.spotify org.breezyweather com.spotify.music com.podimo org.adaway helium314.keyboard com.topjohnwu.magisk com.google.android.apps.maps; do
  chk V21.$p "package $p installed" "pm path $p"
done
chk V22 "no MapsMod / FactoryFix (Vector modules retired)" '! pm path dk.otto.mapsmod && ! pm path dk.otto.factoryfix'
chk V23 "keyboard = HeliBoard" 'settings get secure default_input_method | grep -q helium314.keyboard'

# 7 NAVI (head unit server, any AA version), no system updates
chk V24 "NAVI service (otto_rgid) running" 'pidof otto_rgid'
chk V25 "Android Auto head unit server on 5277 (NAVI)" 'ss -lnt | grep -q ":5277 "'
note "android_auto=$(dumpsys package com.google.android.projection.gearhead | grep -m1 versionName | tr -d ' ')"
chk V26 "automatic system updates off" '[ "$(settings get global ota_disable_automatic_update)" = 1 ]'

# 8 factory menu (English APK, own SELinux prop type)
FAC=$(pm path com.ly.factory 2>/dev/null | head -1 | cut -d: -f2)
chk V27 "factory menu = OTTO English build (sha 1624bdc6)" 'sha256sum '"$FAC"' | grep -q ^1624bdc634fad13bd9af115acf556966d884f2cb275e3ea4287e396102fa77c0'
chk V28 "persist.ctz.adb.config labelled otto_ctz_adb_prop" 'getprop -Z persist.ctz.adb.config | grep -q otto_ctz_adb_prop'
chk V29 "0 denials: composer, USB HAL, factory adb prop" '[ $(dmesg | grep "avc: denied" | grep -E "hal_graphics_composer|vendor_hal_usb_qti|otto_adb_prop|persist.ctz" | wc -l) -eq 0 ]'

# 9 radios
chk V30 "Wi-Fi connected (wlan0 has IPv4)" 'ip -4 addr show wlan0 | grep -q inet'
chk V31 "both Wi-Fi networks saved" '[ $(cmd wifi list-networks 2>/dev/null | grep -cE "${OTTO_SSID_HOME:-<home-ssid>}|${OTTO_SSID_CAR:-<car-ssid>}") -ge 2 ]'
chk V32 "wireless ADB listening on 29527" 'ss -lnt | grep -q ":29527 "'
chk V33 "Bluetooth on" '[ "$(settings get global bluetooth_on)" = 1 ]'
chk V34 "GNSS HAL present" 'service list | grep -qi gnss || lshal | grep -qi gnss'

# 10 car chain: mode follows the AA/CP switch ("latest change wins", ly_link.sh)
chk V35 "ly_link running (OTTO version)" '[ "$(getprop init.svc.ly_link)" = running ] && grep -q persist.otto.last_switch /system/bin/ly_link.sh'
SW=$(cat /sys/class/lzy-aa_cp_switch/switch_state 2>/dev/null)
note "switch_state=$SW adb.config=$(getprop persist.ctz.adb.config) protocol=$(getprop sys.ly.protocol) usb=$(getprop sys.usb.config)"
if [ "$(getprop persist.ctz.adb.config)" = usb ]; then
  chk V36 "wired ADB mode (usb/adb/adb)" '[ "$(getprop sys.ly.protocol)" = adb ] && getprop sys.usb.config | grep -q adb'
else
  chk V36 "wireless mode: CarPlay chain rcp" '[ "$(getprop sys.ly.protocol)" = rcp ] && pidof lylinkservice && pidof lyscrservice'
  chk V37 "USB identity 05ac:12a8" 'grep -qi 0x05ac /config/usb_gadget/g1/idVendor && grep -qi 0x12a8 /config/usb_gadget/g1/idProduct'
fi
chk V38 "ly.verify.state=1 (i2c activation)" '[ "$(getprop ly.verify.state)" = 1 ]'

# 11 display / performance (baked, not module overlays)
chk V39 "60 Hz libsdmcore in vendor (no overlay mount)" '[ -f /vendor/lib64/libsdmcore.so ] && ! mount | grep -q "/data/adb/modules.*libsdmcore"'
chk V40 "HWC VDS enabled" '[ "$(getprop debug.sf.enable_hwc_vds)" = 1 ]'
# Display 2 (mini-HDMI): unchanged behaviour until TV mode is proven (owner 2026-10-23).
if [ -f /data/adb/otto/config/display2_keep_enabled ]; then
  note "display 2 kept enabled by display2_keep_enabled"
else
  chk V40b "display 2 (mini-HDMI) off" '! cmd display get-displays -i 2>/dev/null | grep -qw 2'
fi
chk V41 "boot animation shown (OTTO logo present, not disabled)" '[ -f /system/media/bootanimation.zip ] && [ "$(getprop debug.sf.nobootanimation)" != 1 ]'
chk V42 "ad-block hosts baked (>1000 entries)" '[ $(grep -c -E "^(0\.0\.0\.0|127\.0\.0\.1) " /system/etc/hosts) -gt 1000 ]'
chk V43 "OTTO services up" '[ "$(getprop init.svc.otto_usb0_route)" = running ] && [ "$(getprop init.svc.otto_health)" = running ]'
chk V44 "firstboot done" '[ -f /data/adb/otto/state/firstboot_done ]'

# 12 no OTA (OTA1 bricked slot _a 25-10-2026): updates only via EDL/bootloader
chk V45 "no OTA client in image (FINAL2)" '[ ! -e /system/etc/otto/otto_ota.dex ]'
chk V46 "no update pending or in progress" '[ ! -s /metadata/ota/state ] && [ -z "$(ls /metadata/ota/snapshots 2>/dev/null)" ]'
chk V49 "booted from slot _b, _a not active" '[ "$(getprop ro.boot.slot_suffix)" = _b ]'

# 13 health
chk V47 "no fatal crashes in crash buffer" '[ $(logcat -d -b crash 2>/dev/null | grep -c "FATAL EXCEPTION") -eq 0 ]'
chk V48 "SELinux enforcing" '[ "$(getenforce)" = Enforcing ]'
note "denials total=$(dmesg | grep -c 'avc: denied')  boottime_init=$(getprop ro.boottime.init) uptime=$(cut -d' ' -f1 /proc/uptime)"
echo "RESULT pass=$pass fail=$fail" >> $R
echo "NEXT: measure.sh on Home (target < 5 % janky frames, Maps + 1 overlay layer)" >> $R
echo "MANUAL (car): CarPlay picture + touch, CarPlay audio, SWC next/prev/'Hey Google', GPS fix from car, NAVI on cluster, factory wired/wireless, AA/CP switch, 30-min drive" >> $R
cat $R
