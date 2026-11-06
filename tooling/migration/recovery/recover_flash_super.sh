#!/data/data/com.termux/files/usr/bin/bash
# OTTO — RECOVERY level 2 (bootloader / ABL fastboot). Run by owner in Termux, USB cable phone<->OTTO,
# OTTO already in BOOTLOADER fastboot (adb reboot bootloader, or automatic after an init failure).
#   recover_flash_super.sh a13   -> original Android 13: flash A13 super backup, erase userdata + metadata
#                                   (A13 then starts factory-fresh; CarPlay keys live in privdata1, untouched)
#   recover_flash_super.sh a17   -> re-flash the OTTO A17 super image, erase userdata only (keeps wifi.conf)
#   add --wipe-metadata to the a17 form if the A17 boot complains about encryption/"data may be corrupt"
set -Euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd); FB=termux-fastboot
WHAT=${1:-}; WIPE_MD=${2:-}
TS=$(date +%Y%m%d_%H%M%S); OUT=$PKG/05_LOGS/recover_${WHAT}_$TS; mkdir -p $OUT; exec > >(tee -a $OUT/recover.log) 2>&1
die(){ echo "RECOVERY STOPPED: $*"; exit 1; }
WORK=/data/data/com.termux/files/home/otto_mig_work
case "$WHAT" in
  a13) GZ=$PKG/01_BACKUPS/a13_super/OTTO_A13_super_mmcblk0p19_raw.img.gz; IMG=$WORK/OTTO_A13_super_raw.img
       EXP=$(grep -oE '^[0-9a-f]{64}' $PKG/06_CHECKSUMS/a13_super_raw.sha256 | head -1)
       if [ ! -f $IMG ] || [ "$(sha256sum $IMG | cut -d' ' -f1)" != "$EXP" ]; then
         echo "decompressing A13 super backup to $IMG (sparse, ~5 GB disk) ..."
         gzip -dc $GZ | dd of=$IMG bs=4194304 conv=sparse status=none || die "decompress failed"
         [ "$(sha256sum $IMG | cut -d' ' -f1)" = "$EXP" ] || die "A13 image sha mismatch"
       fi ;;
  a17) IMG=$PKG/02_IMAGES/OTTO_A17_super.simg
       [ "$(sha256sum $IMG | cut -d' ' -f1)" = "$(cut -d' ' -f1 $IMG.sha256)" ] || die "A17 image sha mismatch" ;;
  *) die "usage: recover_flash_super.sh a13|a17 [--wipe-metadata]" ;;
esac
$FB devices | grep -q fastboot || die "no fastboot device — put OTTO in bootloader (adb reboot bootloader)"
$FB getvar all > $OUT/getvar_all.txt 2>&1
grep -q "is-userspace: yes" $OUT/getvar_all.txt && die "this is fastbootd; use the bootloader (fastboot reboot bootloader)"
grep -qi "partition-size:super: 0x180000000" $OUT/getvar_all.txt || die "super size mismatch"
grep -q "current-slot: b" $OUT/getvar_all.txt || $FB --set-active=b
read -r -p "Flash $WHAT super image to OTTO now? skriv JA: " c; [ "$c" = JA ] || die "not confirmed"
$FB flash super $IMG 2>&1 | tee $OUT/flash.txt; grep -qiE "FAILED" $OUT/flash.txt && die "flash failed (device stays in bootloader; retry is safe)"
$FB erase userdata 2>&1 | tee -a $OUT/flash.txt
if [ "$WHAT" = a13 ] || [ "$WIPE_MD" = --wipe-metadata ]; then $FB erase metadata 2>&1 | tee -a $OUT/flash.txt; fi
$FB reboot
echo "== done. $WHAT should boot now (first boot formats data: several minutes)."
