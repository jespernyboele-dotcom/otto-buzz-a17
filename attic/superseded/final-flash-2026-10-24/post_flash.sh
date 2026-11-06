#!/system/bin/sh
# OTTO FINAL: run as root after the first boot of the new image (sh post_flash.sh). Data side of decision C,
# then the full check. The first-boot service (otto_firstboot) has already run by itself at boot_completed.
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for p in com.google.android.apps.restore io.github.seijikohara.femto; do   # Android Switch, plain Femto
  pm path $p >/dev/null 2>&1 && pm uninstall $p && echo "uninstalled $p"
done
ls /data/adb/modules 2>/dev/null | grep -q . && echo "WARNING: Magisk modules present: $(ls /data/adb/modules | tr '\n' ' ')"
sh /data/local/tmp/postboot_verify_device.sh
