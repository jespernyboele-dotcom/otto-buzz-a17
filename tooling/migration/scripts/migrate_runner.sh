#!/data/data/com.termux/files/usr/bin/bash
# OTTO A17 permanent migration — MIGRATION RUNNER. Run ONLY by the owner, manually, in Termux on the phone.
# Never starts by itself. Requires: 07_RECOVERY/RECOVERY_GATE_PASS.env, a fresh 06_CHECKSUMS/PREFLIGHT_PASS.env
# (< 6 h, same manifest), USB cable phone<->OTTO, OTTO on mains power, and a typed confirmation.
#   Phase A (Android/DSU, adb):  re-check; set aside DSU metadata + old vold metadata key (copies kept in
#                                /metadata/otto/migration_saved/<ts>); adb reboot bootloader
#   Phase B (bootloader):        getvar checks; flash super OTTO_A17_super.simg; erase userdata; reboot
#   Phase C (first A17 boot):    wait for Wi-Fi ADB; run postboot_verify (no ART test yet)
# POINT OF NO RETURN = end of Phase A (A13 user data and the DSU are given up). Before that: no change.
set -Euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd); S=<OTTO_IP>:29527; ADB=adb; FB=termux-fastboot
TS=$(date +%Y%m%d_%H%M%S); OUT=$PKG/05_LOGS/migration_$TS; mkdir -p $OUT; LOG=$OUT/migration.log
exec > >(tee -a $LOG) 2>&1
SIMG=$PKG/02_IMAGES/OTTO_A17_super.simg
die(){ echo "MIGRATION STOPPED: $*"; echo "See RECOVERY.md in the package root (log: $LOG)"; exit 1; }
su_(){ $ADB -s $S shell su -c "\"$*\"" 2>/dev/null | tr -d '\r'; }
echo "== OTTO A17 PERMANENT MIGRATION $TS"

# 0 gates
grep -q RECOVERY_GATE=PASS $PKG/07_RECOVERY/RECOVERY_GATE_PASS.env 2>/dev/null || die "recovery gate not passed"
. $PKG/06_CHECKSUMS/PREFLIGHT_PASS.env 2>/dev/null || die "no preflight stamp"
[ "${PREFLIGHT:-}" = PASS ] || die "preflight not PASS"
[ $(( $(date +%s) - DATE_EPOCH )) -lt 21600 ] || die "preflight stamp older than 6 h — run preflight again"
[ "$MANIFEST_SHA" = "$(sha256sum $PKG/06_CHECKSUMS/MANIFEST.sha256 | cut -d' ' -f1)" ] || die "package changed since preflight"
[ "$(sha256sum $SIMG | cut -d' ' -f1)" = "$(cut -d' ' -f1 $SIMG.sha256)" ] || die "A17 super image sha"
echo
echo "Dette gør OTTO's Android 17 permanent. A13 og DSU forsvinder (backup ligger i 01_BACKUPS)."
read -r -p "Skriv præcist  MIGRER OTTO TIL ANDROID 17  for at fortsætte: " c
[ "$c" = "MIGRER OTTO TIL ANDROID 17" ] || die "confirmation not given"

# Phase A
$ADB connect $S >/dev/null 2>&1
[ "$($ADB -s $S shell getprop ro.boot.serialno | tr -d '\r')" = "${OTTO_SERIAL:?set OTTO_SERIAL to your device serial}" ] || die "wrong/no device"
[ "$(su_ sha256sum /dev/block/by-name/super | cut -d' ' -f1)" = "$SUPER_SHA" ] || die "super changed since preflight"
SAVE=/metadata/otto/migration_saved/$TS
su_ "mkdir -p $SAVE && cp -a /metadata/gsi $SAVE/gsi && cp -a /metadata/vold $SAVE/vold && sync" || die "could not save metadata copies"
su_ "test -d $SAVE/gsi/dsu && test -d $SAVE/vold/metadata_encryption" || die "metadata copies incomplete"
echo "Phase A: copies saved in $SAVE. Setting aside DSU state and old vold key (point of no return)."
su_ "rm -rf /metadata/gsi/dsu/* /metadata/vold/metadata_encryption && sync" || die "metadata set-aside failed"
su_ "echo $TS > /metadata/otto/migration_saved/STARTED; sync"
$ADB -s $S reboot bootloader || die "reboot bootloader failed"

# Phase B
for i in $(seq 1 60); do $FB devices 2>/dev/null | grep -q fastboot && break; sleep 2; done
$FB devices | grep -q fastboot || die "bootloader not reached — see RECOVERY.md level 2"
$FB getvar all > $OUT/B_getvar_all.txt 2>&1
grep -q "current-slot: b" $OUT/B_getvar_all.txt || die "current-slot != b"
grep -qi "unlocked: yes" $OUT/B_getvar_all.txt || die "not unlocked"
grep -qi "partition-size:super: 0x180000000" $OUT/B_getvar_all.txt || die "super size mismatch"
grep -q "is-userspace: yes" $OUT/B_getvar_all.txt && die "this is fastbootd, not the bootloader"
echo "Phase B: flashing super (A17) ..."
$FB flash super $SIMG 2>&1 | tee $OUT/B_flash_super.txt
grep -qiE "FAILED|error" $OUT/B_flash_super.txt && die "flash super reported an error — device stays in bootloader; see RECOVERY.md"
echo "Phase B: erasing userdata (fresh A17 userdata) ..."
$FB erase userdata 2>&1 | tee $OUT/B_erase_userdata.txt
grep -qiE "FAILED" $OUT/B_erase_userdata.txt && die "erase userdata failed — see RECOVERY.md"
$FB reboot

# Phase C
echo "Phase C: waiting for the first permanent A17 boot (first boot formats userdata; up to 10 min) ..."
up=0; for i in $(seq 1 200); do $ADB connect $S >/dev/null 2>&1; [ "$($ADB -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && { up=1; break; }; sleep 3; done
[ $up = 1 ] || die "no ADB after 10 min — check screen; see FIRST_BOOT.md / RECOVERY.md"
sleep 60
$ADB -s $S push $PKG/04_SCRIPTS/postboot_verify_device.sh /data/local/tmp/ >/dev/null
$ADB -s $S shell "su -c 'NO_ART_TEST=1 sh /data/local/tmp/postboot_verify_device.sh'" | tee $OUT/C_postboot_verify.txt || \
  $ADB -s $S shell "/debug_ramdisk/su -c 'NO_ART_TEST=1 sh /data/local/tmp/postboot_verify_device.sh'" | tee $OUT/C_postboot_verify.txt
echo "== Phase C done. Next: FIRST_BOOT.md step 3 (provision_restore_device.sh), reboot, verify again with ART test."
