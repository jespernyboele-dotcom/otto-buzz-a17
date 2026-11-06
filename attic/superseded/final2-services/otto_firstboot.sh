#!/system/bin/sh
# OTTO FINAL provisioning. Runs as root (u:r:magisk:s0) at every boot_completed; every step is
# idempotent. It never touches the projection chain. A short record goes to /metadata/otto so a
# boot that cannot be reached over ADB can still be read from A13 afterwards.
# FINAL (2026-10-23): + all Wi-Fi networks, OTTO Home/dock/listeners, Bluetooth, car UI defaults,
# no system updates, HeliBoard, one-time dexopt. Sections marked [PORT1] are
# not yet proven live and must be checked on OTTO before the image is locked.
PATH=/system/bin
O=/data/adb/otto
MD=/metadata/otto
BB=$MD/firstboot.log
PV=$MD/provision
LAUNCHER=io.github.seijikohara.femto.otto
mkdir -p $O/config $O/state $O/logs $O/backups $MD 2>/dev/null
chmod 700 $O $MD 2>/dev/null
[ -f $BB ] && [ "$(stat -c %s $BB 2>/dev/null)" -gt 65536 ] && tail -c 32768 $BB > $BB.tmp && mv $BB.tmp $BB
say() { echo "$(date '+%F %T') boot=$(cat /proc/sys/kernel/random/boot_id) up=$(cut -d' ' -f1 /proc/uptime) $*" >> $BB; }
installed() { pm path "$1" >/dev/null 2>&1; }
say "start release=$(getprop ro.build.version.release) gold=$(grep -m1 '^OTTO_GOLD_ID=' /system/etc/otto/release 2>/dev/null) enforce=$(getenforce 2>/dev/null)"

# A. SetupWizard: ro.setupwizard.mode=DISABLED lets Google's wizard finish by itself.
#    Fallback only if the device is still unprovisioned 60 s after boot.
i=0
while [ $i -lt 30 ] && [ "$(settings get global device_provisioned 2>/dev/null)" != "1" ]; do sleep 2; i=$((i+1)); done
if [ "$(settings get global device_provisioned 2>/dev/null)" != "1" ]; then
  settings put global device_provisioned 1
  settings put secure user_setup_complete 1
  say "provisioned=FORCED"
else
  [ "$(settings get secure user_setup_complete 2>/dev/null)" = "1" ] || settings put secure user_setup_complete 1
  say "provisioned=OK"
fi

# C. Wi-Fi: credentials are NOT in the image. Optional file $PV/wifi.conf (root 0600), one block per
#    network (<home-ssid>, <car-ssid>, ...), blocks separated by an empty line:
#    SSID=<name>   SEC=open|owe|wpa2|wpa3   PSK=<passphrase>
#    Networks are saved (not only connected), so OTTO joins whichever is in range.
wifi_add() {
  [ -n "$SSID" ] || return
  case "$SEC" in open|owe|wpa2|wpa3) ;; *) SEC=wpa2;; esac
  if cmd wifi list-networks 2>/dev/null | grep -qF "$SSID"; then
    say "wifi[$SSID]=ALREADY_SAVED"
  else
    if [ "$SEC" = "open" ] || [ "$SEC" = "owe" ]; then cmd wifi add-network "$SSID" "$SEC" >/dev/null 2>&1; rc=$?
    else cmd wifi add-network "$SSID" "$SEC" "$PSK" >/dev/null 2>&1; rc=$?; fi
    say "wifi[$SSID]=ADDED rc=$rc"
  fi
}
if [ -f $PV/wifi.conf ]; then
  cmd wifi set-wifi-enabled enabled >/dev/null 2>&1
  sleep 3
  SSID=; SEC=wpa2; PSK=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      SSID=*) SSID=${line#SSID=};; SEC=*) SEC=${line#SEC=};; PSK=*) PSK=${line#PSK=};;
      "") wifi_add; SSID=; SEC=wpa2; PSK=;;
    esac
  done < $PV/wifi.conf
  wifi_add
else
  say "wifi=NO_PROVISION_FILE"
fi

# D. root for the ADB shell: the daemon is up without any app; an interactive su needs a policy
#    row. Seed uid 2000 (shell) once, same row as on the A13 service system.
MG=/debug_ramdisk/magisk
[ -x $MG ] || MG=$(command -v magisk)
if [ -n "$MG" ] && [ -x "$MG" ]; then
  if [ -f $PV/no_shell_root ]; then
    say "su_shell=SKIPPED_BY_FILE"
  elif $MG --sqlite "SELECT policy FROM policies WHERE uid=2000" 2>/dev/null | grep -q 'policy=2'; then
    say "su_shell=ALREADY_GRANTED magisk=$($MG -V 2>/dev/null)"
  else
    $MG --sqlite "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (2000,2,0,1,1)" >/dev/null 2>&1
    say "su_shell=SEEDED rc=$? magisk=$($MG -V 2>/dev/null)"
  fi
  # The OTTO launcher uses root silently (voice key, safe zone): grant it without a prompt.
  luid=$(stat -c %u /data/data/$LAUNCHER 2>/dev/null)
  if [ -n "$luid" ]; then
    $MG --sqlite "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($luid,2,0,0,0)" >/dev/null 2>&1
    say "su_launcher=uid$luid rc=$?"
  fi
else
  say "su_shell=NO_MAGISK_BINARY"
fi

# F. OTTO fresh-userdata defaults (FINAL_R1_LIVE_FIX_PROOF fixes 2-4, proven live 2026-10-09;
#    baked into the permanent image 2026-10-18). Idempotent; every boot.
settings put system screen_off_timeout 2147483647
settings put global stay_on_while_plugged_in 15
locksettings set-disabled true >/dev/null 2>&1
settings put secure screensaver_enabled 0
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
  pm grant com.ly.factory android.permission.$p >/dev/null 2>&1
done
say "defaults=APPLIED screen_off=$(settings get system screen_off_timeout) factory_grants=4"

# G. OTTO Home: HOME role, dock (accessibility service), music/Spotify/Android Auto listeners.
#    Proven 2026-10-23: listeners need 'cmd notification allow_listener' (the setting alone is not
#    enough); the dock dies if the launcher is force-stopped, so it is never force-stopped here.
if installed $LAUNCHER; then
  cmd role add-role-holder android.app.role.HOME $LAUNCHER >/dev/null 2>&1
  cmd package set-home-activity $LAUNCHER/$LAUNCHER.OttoHomeActivity >/dev/null 2>&1
  for l in $LAUNCHER/io.github.seijikohara.femto.data.music.MusicSessionListenerService \
           dk.otto.spotify/dk.otto.spotify.MediaAccessListener \
           'com.google.android.projection.gearhead/com.google.android.gearhead.notifications.SharedNotificationListenerManager$ListenerService'; do
    installed "${l%%/*}" && cmd notification allow_listener "$l" >/dev/null 2>&1
  done
  DOCK=$LAUNCHER/.OttoGlobalDockService
  case "$(settings get secure enabled_accessibility_services 2>/dev/null)" in
    *"$DOCK"*) ;;
    *) settings put secure enabled_accessibility_services "$DOCK"; settings put secure accessibility_enabled 1;;
  esac
  for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION BLUETOOTH_CONNECT READ_PHONE_STATE READ_CALENDAR; do
    pm grant $LAUNCHER android.permission.$p >/dev/null 2>&1
  done
  pm grant $LAUNCHER org.breezyweather.READ_PROVIDER >/dev/null 2>&1
  say "home=$(cmd role get-role-holders android.app.role.HOME) dock=$(settings get secure enabled_accessibility_services)"
else
  say "home=LAUNCHER_MISSING"
fi
for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION; do
  pm grant org.breezyweather android.permission.$p >/dev/null 2>&1
  pm grant com.google.android.apps.maps android.permission.$p >/dev/null 2>&1
done
# Maps never goes picture-in-picture: other apps get the whole screen and the safe zone stays off for
# them; navigation goes on in the background (voice, and the cluster through NAVI). Proven 2026-10-24.
appops set com.google.android.apps.maps PICTURE_IN_PICTURE ignore
# No "Hey Google": its hotword listener cost ~8 % CPU all the time. Only next/prev on the wheel are used (they go
# through the media session). Voice search by tap still works. the owner's choice, car test 2026-10-25.
pm disable com.google.android.googlequicksearchbox/com.google.android.apps.gsa.hotword.hotworddetectionservice.GsaHotwordDetectionService >/dev/null 2>&1

# H. Bluetooth on (the old restore script left it off: F13).
[ "$(settings get global bluetooth_on 2>/dev/null)" = "1" ] || { cmd bluetooth_manager enable >/dev/null 2>&1; say "bluetooth=ENABLED"; }

# I. Car UI defaults: dark, no heads-up pop-ups, Danish (locale applies from the next boot).
cmd uimode night yes >/dev/null 2>&1
settings put global heads_up_notifications_enabled 0
[ -n "$(getprop persist.sys.locale)" ] || setprop persist.sys.locale da-DK
# Animations at half length (snappier on the car screen; owner 2026-10-25).
for a in window_animation_scale transition_animation_scale animator_duration_scale; do settings put global $a 0.5; done
# Apps a car box never uses: off, not removed (pm enable brings one back). Frees ~0.7 GB RAM (measured 2026-10-25).
# Setup Wizard is safe to disable here: section A has already provisioned the device.
for p in com.google.android.apps.messaging com.google.android.apps.wellbeing com.android.chrome \
         com.google.android.apps.photos com.google.android.syncadapters.calendar com.google.android.setupwizard; do
  pm disable-user --user 0 $p >/dev/null 2>&1
done
say "animations=$(settings get global animator_duration_scale) disabled=$(pm list packages -d 2>/dev/null | wc -l)"

# J. No system updates (owner 2026-10-23). The GSI has no OTA; Google's own update paths are
#    switched off. Play Store keeps auto-updating all apps (K).
settings put global ota_disable_automatic_update 1
for c in com.google.android.gms/.update.SystemUpdateActivity \
         com.google.android.gms/.update.SystemUpdateService \
         com.google.android.gms/.update.SystemUpdateGcmTaskService; do
  pm disable --user 0 "$c" >/dev/null 2>&1
done
say "updates=OFF ota_auto=$(settings get global ota_disable_automatic_update)"

# K. Android Auto updates with Play like every app: the NAVI bridge speaks the head unit protocol
#    (port 5277), which does not depend on the version. Only recorded for the log.
say "android_auto=$(dumpsys package com.google.android.projection.gearhead 2>/dev/null | grep -m1 versionName | tr -d ' ')"

# L. Keyboard: HeliBoard (has a hide key; styled like the launcher), Gboard stays as fallback.
HB=helium314.keyboard/.latin.LatinIME
if installed helium314.keyboard; then
  ime enable $HB >/dev/null 2>&1
  [ "$(settings get secure default_input_method)" = "$HB" ] || ime set $HB >/dev/null 2>&1
  say "ime=$(settings get secure default_input_method)"
fi

# E/observability: one line of state for the record.
sleep 20
say "state adb_port=$(getprop service.adb.tcp.port) listen29527=$(ss -lnt 2>/dev/null | grep -c ':29527 ') wlan0=$(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}') usbcfg=$(getprop sys.usb.config) lyproto=$(getprop sys.ly.protocol) ly_link=$(getprop init.svc.ly_link) lylink=$(pidof lylinkservice) lyscr=$(pidof lyscrservice) applay=$(pidof com.ap.play) mylink=$(pidof com.cartizan.mylink) home=$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -1)"
date '+%F %T' > $O/state/firstboot_done

# M. One-time dexopt 'speed' for everything (F4: prebuilt odex of 24 system apps is rejected).
#    Last and in the foreground at low priority: init kills a service's process group when the
#    script exits, so a background job would not survive. Once per installed image.
IMG=$(getprop ro.build.fingerprint)
if [ "$(cat $O/state/dexopt_done 2>/dev/null)" != "$IMG" ]; then
  say "dexopt=STARTED"
  nice -n 19 cmd package compile -m speed -a >/dev/null 2>&1; rc=$?
  [ $rc = 0 ] && echo "$IMG" > $O/state/dexopt_done
  say "dexopt=DONE rc=$rc"
fi
exit 0
