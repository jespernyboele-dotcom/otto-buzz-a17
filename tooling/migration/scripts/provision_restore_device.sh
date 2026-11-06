#!/system/bin/sh
# OTTO A17 permanent — restore the captured DSU-era state onto the FRESH userdata after the first
# permanent boot. Runs ON OTTO as root (adb shell su -c ...). Idempotent; safe to re-run.
# Input: the bundle pushed to /data/local/tmp/otto_a17_state (= 01_BACKUPS/a17_userdata_state).
# Phases (each logged to $LOG):  A checks  B APKs  C /data/adb  D app data  E settings/roles/perms
#                                F Wi-Fi/BT/persist props  G summary.  Ends WITHOUT reboot; reboot manually
#                                (modules + Vector + restored Wi-Fi/BT need one reboot).
B=/data/local/tmp/otto_a17_state
LOG=/data/local/tmp/otto_provision_restore.log
say(){ echo "$(date '+%F %T') $*" | tee -a $LOG; }
fail(){ say "STOP: $*"; exit 1; }
say "=== provision_restore start boot=$(cat /proc/sys/kernel/random/boot_id)"

# A. checks
[ "$(id -u)" = 0 ] || fail "not root"
[ "$(getprop sys.boot_completed)" = 1 ] || fail "boot not completed"
[ -f /metadata/gsi/dsu/booted ] && fail "this is a DSU boot — run only on the permanent installation"
case "$(getprop ro.build.fingerprint)" in *:17/*) ;; *) fail "not Android 17";; esac
[ -f $B/SHA256SUMS ] || fail "bundle missing at $B"
( cd $B && grep -v ' ./capture.log$' SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ) || fail "bundle checksum mismatch"
say "A checks OK fp=$(getprop ro.build.fingerprint) slot=$(getprop ro.boot.slot_suffix)"

# B. APKs (Magisk app first, then the rest); already-installed same version is skipped by pm
for d in $B/apks/com.topjohnwu.magisk $(ls -d $B/apks/* | grep -v com.topjohnwu.magisk); do
  pkg=$(basename $d); n=$(ls $d/*.apk | wc -l)
  if [ $n -gt 1 ]; then out=$(pm install-multiple -r $d/*.apk 2>&1); else out=$(pm install -r $d/base.apk 2>&1); fi
  say "B apk $pkg -> $out"
done

# C. /data/adb (modules, scripts, Magisk db, Vector/lspd, OTTO state, NAVI) + exact SELinux labels
mkdir -p /data/adb
tar -xzf $B/data_adb.tgz -C /data 2>>$LOG; say "C data_adb extract rc=$?"
if [ -f $B/data_adb_contexts.txt ]; then
  ok=0; bad=0
  while read -r line; do
    p=${line##* }; ctx=$(echo "$line" | grep -oE 'u:object_r:[a-z_0-9]+:s0')
    [ -e "$p" ] && [ -n "$ctx" ] || continue
    chcon -h "$ctx" "$p" 2>/dev/null && ok=$((ok+1)) || bad=$((bad+1))
  done < $B/data_adb_contexts.txt
  say "C contexts applied ok=$ok failed=$bad (failures expected only for types unknown to the loaded policy)"
fi
rm -f /data/adb/modules/*/remove 2>/dev/null

# D. app data of OTTO apps: stop app, extract, chown to the NEW uid, restorecon
for f in $B/appdata/*.ce.tgz; do
  pkg=$(basename $f .ce.tgz); [ -d /data/data/$pkg ] || { say "D skip $pkg (not installed)"; continue; }
  am force-stop $pkg; uid=$(stat -c %u /data/data/$pkg)
  tar -xzf $f -C /data/data 2>>$LOG
  [ -f $B/appdata/$pkg.de.tgz ] && tar -xzf $B/appdata/$pkg.de.tgz -C /data/user_de/0 2>>$LOG
  chown -R $uid:$uid /data/data/$pkg /data/user_de/0/$pkg 2>/dev/null
  restorecon -RF /data/data/$pkg /data/user_de/0/$pkg 2>/dev/null
  say "D appdata $pkg restored uid=$uid"
done

# E. HOME role, listeners, accessibility (dock), runtime permissions
cmd role add-role-holder android.app.role.HOME io.github.seijikohara.femto.otto 2>&1 | tee -a $LOG
cmd package set-home-activity io.github.seijikohara.femto.otto/io.github.seijikohara.femto.otto.OttoHomeActivity 2>&1 | tee -a $LOG
nl=$(cat $B/settings/notification_listeners.txt); [ -n "$nl" ] && [ "$nl" != null ] && settings put secure enabled_notification_listeners "$nl"
ac=$(cat $B/settings/accessibility.txt); [ -n "$ac" ] && [ "$ac" != null ] && { settings put secure enabled_accessibility_services "$ac"; settings put secure accessibility_enabled 1; }
for f in $B/perms/*.granted; do
  pkg=$(basename $f .granted); pm path $pkg >/dev/null 2>&1 || continue
  while read -r perm; do [ -n "$perm" ] && pm grant $pkg $perm 2>/dev/null; done < $f
done
say "E roles/listeners/accessibility/permissions applied home=$(cmd role get-role-holders android.app.role.HOME)"
# OTTO fresh-userdata defaults (also in otto_firstboot.sh of the OTTO image; repeated here, idempotent)
settings put system screen_off_timeout 2147483647; settings put global stay_on_while_plugged_in 15
settings put secure screensaver_enabled 0; locksettings set-disabled true >/dev/null 2>&1

# F. Wi-Fi networks, Bluetooth pairings, OTTO persist props
if [ -f $B/sys/WifiConfigStore.xml ]; then
  cp $B/sys/WifiConfigStore.xml /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml.otto_restore
  say "F Wi-Fi store staged as .otto_restore (main network comes from /metadata/otto/provision/wifi.conf; see RECOVERY.md to activate the full store)"
fi
[ -f $B/sys/bluetooth.tgz ] && { svc bluetooth disable 2>/dev/null; sleep 2; tar -xzf $B/sys/bluetooth.tgz -C /data/misc 2>>$LOG; chown -R bluetooth:bluetooth /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null; restorecon -RF /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null; say "F bluetooth restored"; }
grep -E '^\[persist\.(carplay|ctz|ly|otto|hugps|navi)' $B/sys/persist_props.txt | while read -r l; do
  k=$(echo "$l" | sed 's/^\[\([^]]*\)\].*/\1/'); v=$(echo "$l" | sed 's/^[^:]*: \[\(.*\)\]$/\1/')
  [ "$(getprop $k)" = "$v" ] || { setprop "$k" "$v"; say "F setprop $k=$v"; }
done

# G. summary
say "G modules=$(ls /data/adb/modules | tr '\n' ' ')"
say "G next: reboot once (adb reboot), then run postboot_verify_device.sh"
say "=== provision_restore done"
