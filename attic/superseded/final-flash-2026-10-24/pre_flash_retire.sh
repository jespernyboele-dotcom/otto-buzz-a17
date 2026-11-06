#!/system/bin/sh
# OTTO FINAL: run as root on the OLD system right before the EDL flash (sh pre_flash_retire.sh).
# Everything below is baked into OTTO_A17_FINAL_super; left in /data it would run a second time on the first boot
# (Magisk would mount the modules over the image and start NAVI + the boot scripts twice). Nothing is deleted:
# it is moved to /data/adb/otto/retired_20261024 and can be moved back to return to today's setup.
R=/data/adb/otto/retired_20261024
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
mkdir -p $R/modules $R/service.d $R/post-fs-data.d
for m in /data/adb/modules/*; do [ -d "$m" ] && mv "$m" $R/modules/ && echo "retired module $(basename $m)"; done
for d in service.d post-fs-data.d; do
  for f in /data/adb/$d/*.sh; do [ -f "$f" ] && mv "$f" $R/$d/ && echo "retired $d/$(basename $f)"; done
done
# boot animation: the OTTO logo is in the image now; the boot-only "no animation" step would hide it
rm -f /data/adb/otto/config/boot_a1 && echo "boot_a1 marker removed (logo will show)"
# Zygisk off for good (Vector is retired with the modules)
magisk --sqlite "REPLACE INTO settings (key,value) VALUES('zygisk',0)" >/dev/null 2>&1
sync
echo "AA/CP switch must be on CP. Now: power off OTTO, EDL, flash OTTO_A17_FINAL_super.simg."
