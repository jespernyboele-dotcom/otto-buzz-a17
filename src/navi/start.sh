#!/system/bin/sh
# OTTO NAVI starter (image version of the former Magisk module's service.sh): installs the engine, the jars and the
# shipped receiver profiles into /data/adb/otto_navi (an edited profile is kept), then becomes the supervisor itself
# (exec), so it stays the process of the init service otto_navi.
M=/system/etc/otto/navi
[ "$(getprop ro.build.version.release)" = "17" ] || exit 0
mkdir -p /data/adb/otto_navi/bin /data/adb/otto_navi/profiles
cp -f $M/bin/otto_aanav.jar $M/bin/otto_rgid $M/bin/otto_cargps.jar /data/adb/otto_navi/bin/
chmod 0755 /data/adb/otto_navi/bin/otto_rgid
for p in $M/profiles/*.conf; do [ -f "/data/adb/otto_navi/profiles/${p##*/}" ] || cp "$p" /data/adb/otto_navi/profiles/; done
exec /system/bin/sh $M/otto_navi.sh </dev/null >/dev/null 2>&1
