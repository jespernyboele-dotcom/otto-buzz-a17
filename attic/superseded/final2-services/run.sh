#!/system/bin/sh
# OTTO FINAL (2026-10-24): runs the former Magisk boot scripts, now shipped in the image, in name order.
# $1 = post-fs-data (before SurfaceFlinger) or service (after boot). Opt-outs and logs stay in /data/adb/otto.
mkdir -p /data/adb/otto/config /data/adb/otto/logs /data/adb/otto/state
for f in /system/etc/otto/boot/$1.d/*.sh; do [ -f "$f" ] && /system/bin/sh "$f"; done
exit 0
