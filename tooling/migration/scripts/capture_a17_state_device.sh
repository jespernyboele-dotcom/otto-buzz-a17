#!/system/bin/sh
# OTTO A17 permanent migration — capture the running A17 (DSU) userdata state that must be restored
# on the fresh userdata after migration. Runs ON OTTO as root. Read-only except $OUT.
# Usage: adb -s <OTTO_IP>:29527 shell su -c sh /data/local/tmp/capture_a17_state_device.sh
OUT=/data/local/tmp/otto_a17_state
rm -rf $OUT; mkdir -p $OUT/apks $OUT/appdata $OUT/settings $OUT/perms $OUT/sys
LOG=$OUT/capture.log
say(){ echo "$(date '+%F %T') $*" | tee -a $LOG; }
say "capture start boot=$(cat /proc/sys/kernel/random/boot_id) fp=$(getprop ro.build.fingerprint)"

# 1. /data/adb (Magisk db, modules, service.d, post-fs-data.d, Vector/lspd config, OTTO state, NAVI)
tar -czf $OUT/data_adb.tgz -C /data --exclude=adb/otto/bootlogs adb 2>>$LOG; say "data_adb.tgz rc=$? $(stat -c %s $OUT/data_adb.tgz)"

# 2. third-party APKs (base + splits), with the package list
pm list packages -3 -f --show-versioncode | sort > $OUT/packages3.txt
for line in $(sed 's/^package://' $OUT/packages3.txt | awk '{print $1}'); do
  apk=${line%=*}; pkg=${line##*=}; dir=$(dirname $apk)
  mkdir -p $OUT/apks/$pkg; cp $dir/*.apk $OUT/apks/$pkg/ 2>>$LOG
  say "apk $pkg $(ls $OUT/apks/$pkg | tr '\n' ' ')"
done

# 3. app data of OTTO's own apps (settings/prefs; no login tokens of third-party apps)
for pkg in io.github.seijikohara.femto.otto io.github.seijikohara.femto dk.otto.spotify dk.otto.mapsmod dk.otto.factoryfix org.breezyweather; do
  [ -d /data/data/$pkg ] || continue
  tar -czf $OUT/appdata/$pkg.ce.tgz -C /data/data --exclude=$pkg/cache --exclude=$pkg/code_cache $pkg 2>>$LOG
  [ -d /data/user_de/0/$pkg ] && tar -czf $OUT/appdata/$pkg.de.tgz -C /data/user_de/0 $pkg 2>>$LOG
  say "appdata $pkg uid=$(stat -c %u /data/data/$pkg)"
done

# 4. settings, roles, listeners, accessibility
for ns in global secure system; do settings list $ns > $OUT/settings/$ns.txt; done
cmd role get-role-holders android.app.role.HOME > $OUT/settings/role_home.txt
settings get secure enabled_notification_listeners > $OUT/settings/notification_listeners.txt
settings get secure enabled_accessibility_services > $OUT/settings/accessibility.txt

# 5. runtime permissions + appops per third-party package and com.ly.factory
for pkg in $(sed 's/.*=//; s/ .*//' $OUT/packages3.txt) com.ly.factory com.ap.play com.cartizan.mylink; do
  dumpsys package $pkg | grep -E "android.permission.[A-Z_]+: granted=true" | sed 's/^ *//; s/:.*//' | sort -u > $OUT/perms/$pkg.granted
  appops get $pkg > $OUT/perms/$pkg.appops 2>/dev/null
done

# 6. system files: Wi-Fi networks, Bluetooth pairings, persistent properties, OTTO metadata
cp -p /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml $OUT/sys/ 2>>$LOG
tar -czf $OUT/sys/bluetooth.tgz -C /data/misc bluedroid bluetooth 2>>$LOG
cp -p /data/property/persistent_properties $OUT/sys/ 2>>$LOG
getprop | grep -E '^\[persist\.' > $OUT/sys/persist_props.txt
tar -czf $OUT/sys/metadata_otto.tgz -C /metadata otto 2>>$LOG
ls -la /metadata/otto/provision > $OUT/sys/metadata_provision_ls.txt 2>&1

# 7. manifest
cd $OUT && find . -type f ! -name SHA256SUMS -exec sha256sum {} \; | sort -k2 > SHA256SUMS
chmod -R a+rX $OUT
say "capture done files=$(find $OUT -type f | wc -l) bytes=$(du -sk $OUT | cut -f1)k"
