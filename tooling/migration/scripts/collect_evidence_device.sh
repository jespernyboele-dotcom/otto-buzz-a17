#!/system/bin/sh
# OTTO A17 permanent migration — read-only evidence collector (runs ON the OTTO box as root).
# Writes nothing outside $OUT. Never writes to a block device, never changes props, never reboots.
# Usage (from phone Termux):
#   adb -s <OTTO_IP>:29527 push collect_evidence_device.sh /data/local/tmp/
#   adb -s <OTTO_IP>:29527 shell su -c sh /data/local/tmp/collect_evidence_device.sh
#   adb -s <OTTO_IP>:29527 pull /data/local/tmp/otto_mig_evidence <dest>
OUT=/data/local/tmp/otto_mig_evidence
rm -rf $OUT; mkdir -p $OUT
rec(){ n=$1; shift; { echo "# $*"; sh -c "$*"; echo "# rc=$?"; } > $OUT/$n.txt 2>&1; }

rec 00_identity   'date; uname -a; cat /proc/version; getprop ro.build.fingerprint; getprop ro.product.model; getprop ro.boot.serialno; getprop ro.serialno; cat /sys/devices/soc0/soc_id /sys/devices/soc0/machine 2>/dev/null; cat /proc/sys/kernel/random/boot_id'
rec 01_getprop    'getprop'
rec 02_cmdline    'cat /proc/cmdline; echo; echo "--- bootconfig"; cat /proc/bootconfig 2>/dev/null'
rec 03_byname     'ls -la /dev/block/by-name/ 2>/dev/null || ls -la /dev/block/platform/*/by-name/'
rec 04_partsizes  'for p in /dev/block/by-name/*; do n=$(basename $p); d=$(readlink -f $p); s=$(blockdev --getsize64 $d 2>/dev/null); ro=$(blockdev --getro $d 2>/dev/null); echo "$n $d $s ro=$ro"; done'
rec 05_proc_partitions 'cat /proc/partitions'
rec 06_lpdump     'lpdump 2>&1; echo "--- slot 0"; lpdump -s 0 2>&1 | head -5; echo "--- slot 1"; lpdump -s 1 2>&1 | head -5'
rec 07_dmsetup    'dmctl list devices 2>/dev/null; for d in $(dmctl list devices 2>/dev/null | awk "NR>1{print \$1}"); do echo "== $d"; dmctl table $d 2>/dev/null; done'
rec 08_mounts     'cat /proc/mounts; echo; df -h 2>/dev/null'
rec 09_gsi        'gsi_tool status 2>&1; echo "--- /data/gsi"; ls -laR /data/gsi 2>&1 | head -80; echo "--- /metadata/gsi"; ls -laR /metadata/gsi 2>&1 | head -80; for f in /metadata/gsi/dsu/* /metadata/gsi/dsu/*/*; do [ -f "$f" ] && { echo "== $f ($(stat -c %s "$f"))"; head -c 600 "$f" | strings | head -20; }; done'
rec 10_fstab      'ls -la /vendor/etc/fstab* /odm/etc/fstab* /system/etc/fstab* /first_stage_ramdisk/ 2>&1; for f in /vendor/etc/fstab.* ; do echo "== $f"; cat $f; done'
rec 11_avb        'avbctl get-verity 2>&1; avbctl get-verification 2>&1; getprop | grep -iE "verifiedboot|vbmeta|avb|verity|flash.locked|secure|unlocked|warranty"'
rec 12_vbmeta_hdr 'for p in vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b; do [ -e /dev/block/by-name/$p ] || continue; echo "== $p"; dd if=/dev/block/by-name/$p bs=256 count=1 2>/dev/null | od -A d -t x1 | head -16; done'
rec 13_bootctl    'bootctl get-current-slot 2>&1; bootctl get-suffix 0 2>&1; bootctl get-suffix 1 2>&1; for s in 0 1; do echo "slot $s bootable=$(bootctl is-slot-bootable $s 2>&1; echo $?) marked=$(bootctl is-slot-marked-successful $s 2>&1; echo $?)"; done; bootctl get-snapshot-merge-status 2>&1'
rec 14_bootimg_hdr 'for p in boot_a boot_b init_boot_a init_boot_b vendor_boot_a vendor_boot_b recovery_a recovery_b dtbo_a dtbo_b; do [ -e /dev/block/by-name/$p ] || continue; h=$(dd if=/dev/block/by-name/$p bs=4096 count=1 2>/dev/null | od -A n -c -N 8 | tr -d " \n"); v=$(dd if=/dev/block/by-name/$p bs=1 skip=40 count=4 2>/dev/null | od -A n -t u4 | tr -d " "); echo "$p magic=$h hdr_ver_at40=$v"; done'
rec 15_bootimg_sha 'for p in boot_a boot_b init_boot_a init_boot_b vendor_boot_a vendor_boot_b recovery_a recovery_b dtbo_a dtbo_b vbmeta_a vbmeta_b vbmeta_system_a vbmeta_system_b; do [ -e /dev/block/by-name/$p ] || continue; echo "$(sha256sum /dev/block/by-name/$p | cut -d" " -f1) $p"; done'
rec 16_magisk     'magisk -v; magisk -V; magisk --path; ls -la /data/adb/; ls -la /data/adb/magisk 2>&1 | head; cat /data/adb/magisk/util_functions.sh 2>/dev/null | grep -m2 MAGISK_VER; magisk --sqlite "SELECT * FROM settings" 2>&1; magisk --sqlite "SELECT * FROM policies" 2>&1; magisk --denylist ls 2>&1 | head'
rec 17_modules    'for m in /data/adb/modules/*; do echo "== $m"; cat $m/module.prop 2>/dev/null; ls -la $m; [ -f $m/disable ] && echo DISABLED; done'
rec 18_scripts    'for d in /data/adb/post-fs-data.d /data/adb/service.d; do echo "== $d"; ls -la $d; for f in $d/*; do echo "--- $f $(sha256sum $f | cut -c1-16)"; done; done; echo "== /data/adb/otto"; ls -laR /data/adb/otto 2>&1 | head -60'
rec 19_sepolicy   'getenforce; ls -la /system/etc/selinux /vendor/etc/selinux /odm/etc/selinux 2>&1; sha256sum /system/etc/selinux/* /vendor/etc/selinux/* 2>/dev/null; grep -c . /system/etc/selinux/plat_sepolicy.cil; grep -n -i otto /system/etc/selinux/plat_sepolicy.cil | head -40; for m in /data/adb/modules/*; do [ -f $m/sepolicy.rule ] && { echo "== $m/sepolicy.rule"; cat $m/sepolicy.rule; }; done'
rec 20_otto_system 'ls -la /system/etc/init/ | grep -iE "otto|ly"; for f in /system/etc/init/otto*; do echo "== $f"; cat $f; done; ls -la /system/bin | grep -iE "otto|ly"; ls -la /system/app /system/priv-app | grep -iE "ly|otto|cartizan|play"'
rec 21_packages   'pm list packages -f -U --show-versioncode 2>&1 | sort'
rec 22_packages3  'pm list packages -3 -f --show-versioncode 2>&1 | sort; echo; cmd role get-role-holders android.app.role.HOME 2>&1; cmd package resolve-activity -c android.intent.category.HOME -a android.intent.action.MAIN 2>&1 | head -5'
rec 23_dexopt     'dumpsys package dexopt 2>&1 | grep -E "^\s*\[|status=" | head -400'
rec 24_services   'getprop | grep -E "init.svc\." | sort'
rec 25_vector     'ls -la /data/adb/modules/zygisk_vector 2>&1; cat /data/adb/modules/zygisk_vector/module.prop 2>&1; ls -la /data/adb/lspd /data/adb/vector 2>&1 | head -30; mount | grep -iE "dex2oat|xposed|vector" '
rec 26_usb        'getprop | grep -iE "usb|ly\."; ls /config/usb_gadget/g1/configs/*/ 2>&1; cat /config/usb_gadget/g1/idVendor /config/usb_gadget/g1/idProduct 2>&1'
rec 27_privdata   'ls -la /dev/block/by-name/ | grep -iE "privdata|persist|metadata|modem|fsg|fsc|modemst|oem|devinfo|misc|frp|super|userdata|keymaster|keystore"; blkid 2>/dev/null | head -60'
rec 28_metadata   'ls -la /metadata 2>&1; ls -la /metadata/* 2>&1 | head -60; ls -la /metadata/vold/metadata_encryption 2>&1'
rec 29_storage    'df -h /data /metadata /cache 2>&1; du -sh /data/gsi 2>/dev/null; du -sh /data/app /data/data /data/adb /data/media 2>/dev/null'
rec 30_userdata   'getprop ro.crypto.state; getprop ro.crypto.type; getprop ro.crypto.metadata.enabled; ls -la /data/unencrypted 2>&1; getprop | grep -iE "fbe|encrypt|vold"'
rec 31_kernel_modules 'cat /proc/modules | wc -l; ls /vendor/lib/modules 2>/dev/null | wc -l; ls /vendor_dlkm/lib/modules 2>/dev/null | wc -l; ls /system_dlkm/lib/modules 2>/dev/null | head'
rec 32_misc_bcb   'dd if=/dev/block/by-name/misc bs=1 count=96 2>/dev/null | od -A d -c | head -8'
rec 33_devinfo    'for p in devinfo devinfo_a devinfo_b; do [ -e /dev/block/by-name/$p ] && { echo == $p; dd if=/dev/block/by-name/$p bs=512 count=1 2>/dev/null | od -A d -c | head -12; }; done'
chmod -R a+rX $OUT
echo "done: $(ls $OUT | wc -l) files in $OUT"
