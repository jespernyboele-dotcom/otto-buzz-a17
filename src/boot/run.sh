#!/system/bin/sh
# OTTO FINAL (2026-10-24, F4 2026-10-31): runs the former Magisk boot scripts, shipped in the image.
# $1 = post-fs-data (before SurfaceFlinger): in name order, blocking, as before.
# $1 = service (after boot): in parallel. Each script still waits for sys.boot_completed and its own settle time, but the
#      waits no longer add up (FINAL2 ran them one after another: VDS confirmed at ~190 s, SF/GPU placement at ~150 s).
#      24-otto-a3a-gpu465 (F14) applies at BOOT_COMPLETED and again 60 s later, so composer threads started by
#      20-otto-display2-off are moved too; no ordering needed.
# Opt-outs and logs stay in /data/adb/otto.
mkdir -p /data/adb/otto/config /data/adb/otto/logs /data/adb/otto/state
D=/system/etc/otto/boot/$1.d
if [ "$1" != service ]; then
  for f in $D/*.sh; do [ -f "$f" ] && /system/bin/sh "$f"; done
  exit 0
fi
for f in $D/*.sh; do
  [ -f "$f" ] && /system/bin/sh "$f" &
done
wait
exit 0
