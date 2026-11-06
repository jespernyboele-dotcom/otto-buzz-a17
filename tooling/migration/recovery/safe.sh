#!/data/data/com.termux/files/usr/bin/bash
# OTTO A17 permanent migration — RECOVERY GATE (run by owner in Termux on the phone; USB cable to OTTO).
# Proves, WITHOUT writing any partition, that the three recovery transports work on this unit TODAY:
#   G1 bootloader (ABL) fastboot reachable:    adb reboot bootloader -> getvar all -> reboot
#   G2 userspace fastbootd reachable:          adb reboot fastboot   -> getvar all -> reboot
#   G3 EDL via the PHYSICAL EDL button:        05c6:9008 -> Sahara -> Firehose -> GPT check ->
#      full read of init_boot_b, using the UNMODIFIED proven R29E worker in its no-write branch
#      (target image == current content => STATUS=CLOSED_ALREADY_PATCHED_EXACT, then power reset)
# Writes only: its own log folder and, on success, the stamp 07_RECOVERY/RECOVERY_GATE_PASS.env.
# Each step asks before rebooting. Expected duration 10-15 min.
set -Euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd)
S=<OTTO_IP>:29527
TS=$(date +%Y%m%d_%H%M%S); OUT=$PKG/05_LOGS/recovery_gate_$TS; mkdir -p $OUT
LOG=$OUT/recovery_gate.log; exec > >(tee -a $LOG) 2>&1
FB=termux-fastboot; ADB=adb
EDL=$PKG/04_SCRIPTS/edl
GPT_SHA=712ca75b50cb24cec9e9a7beaf3a2bdeb1871d3a0a7276fad5243456edf1d181
IB=$PKG/01_BACKUPS/boot_chain/init_boot_b.img
die(){ echo "GATE FAIL: $*"; echo "RESULT=FAIL step=$*" > $OUT/RESULT.env; exit 1; }
ask(){ read -r -p "$1 [ja/nej] " a; [ "$a" = ja ] || die "aborted by operator at: $1"; }
waitadb(){ for i in $(seq 1 90); do $ADB connect $S >/dev/null 2>&1; [ "$($ADB -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0; sleep 3; done; return 1; }
fbwait(){ for i in $(seq 1 60); do $FB devices 2>/dev/null | grep -q fastboot && return 0; sleep 2; done; return 1; }
echo "== OTTO RECOVERY GATE $TS"
command -v $FB >/dev/null || die "termux-fastboot missing"; command -v termux-usb >/dev/null || die "termux-usb missing"
[ -f $IB ] || die "init_boot_b backup missing ($IB)"
IB_SHA=$(sha256sum $IB | cut -d' ' -f1)
waitadb || die "OTTO not reachable on $S"
[ "$($ADB -s $S shell getprop ro.boot.serialno | tr -d '\r')" = "${OTTO_SERIAL:?set OTTO_SERIAL to your device serial}" ] || die "wrong device"
LIVE_IB=$($ADB -s $S shell su -c "sha256sum /dev/block/by-name/init_boot_b" | cut -d' ' -f1)
[ "$LIVE_IB" = "$IB_SHA" ] || die "init_boot_b changed since backup (live $LIVE_IB vs backup $IB_SHA)"
echo "init_boot_b live == backup ($IB_SHA)"

# G1 ABL
ask "G1: genstart OTTO til bootloader (fastboot)? USB-kablet skal sidde i"
$ADB -s $S reboot bootloader; sleep 8; fbwait || die "G1 bootloader fastboot did not enumerate"
$FB getvar all > $OUT/G1_abl_getvar_all.txt 2>&1
grep -q "current-slot: b" $OUT/G1_abl_getvar_all.txt || die "G1 current-slot != b"
grep -qiE "unlocked: yes" $OUT/G1_abl_getvar_all.txt || die "G1 not unlocked"
grep -qiE "partition-size:super: 0x180000000" $OUT/G1_abl_getvar_all.txt || die "G1 super size mismatch"
grep -E "max-download-size|is-userspace|partition-size:super|partition-size:userdata|partition-size:metadata" $OUT/G1_abl_getvar_all.txt
echo "G1 PASS"; $FB reboot; waitadb || die "G1 Android did not come back"

# G2 fastbootd
ask "G2: genstart OTTO til fastbootd (patched recovery_b)?"
$ADB -s $S reboot fastboot; sleep 10; fbwait || die "G2 fastbootd did not enumerate"
$FB getvar all > $OUT/G2_fastbootd_getvar_all.txt 2>&1
grep -q "is-userspace: yes" $OUT/G2_fastbootd_getvar_all.txt || die "G2 not userspace fastbootd"
grep -E "current-slot|super-partition-name|partition-size:system_b|snapshot-update-status" $OUT/G2_fastbootd_getvar_all.txt
echo "G2 PASS"; $FB reboot; waitadb || die "G2 Android did not come back"

# G3 EDL via the physical button, proven worker in no-write branch
echo "G3: sluk OTTO, hold den fysiske EDL/recovery-knap inde og tænd (samme som du plejer)."
ask "G3: er OTTO nu i EDL (skærm sort)? Fortsæt med USB-scan"
USB=""; for i in $(seq 1 40); do mapfile -t U < <(termux-usb -l 2>/dev/null | grep -o '/dev/bus/usb/[0-9]\{3\}/[0-9]\{3\}' | sort -u); [ ${#U[@]} -eq 1 ] && { USB=${U[0]}; break; }; sleep 1; done
[ -n "$USB" ] || die "G3 no single USB device (expected 05c6:9008)"
mkdir -p $OUT/G3_firehose
export OTTO_TERMUX_USB_PATH=$USB OTTO_ENGINE=$EDL/root_reader_R29E_STRICT_READ_ONLY.py OTTO_PROGRAMMER=$EDL/goco7.bin \
  OTTO_PATCHED=$IB OTTO_STOCK_REF=$IB OTTO_OUTENV=$OUT/G3_RESULT.env OTTO_RAWLOG=$OUT/G3_raw.hexlog \
  OTTO_EVIDENCE=$OUT/G3_firehose OTTO_LEDGER=$OUT/G3_ledger.tsv OTTO_FIRST_LBA=16646160 OTTO_LAST_LBA=16662543 \
  OTTO_TARGET_BYTES=8388608 OTTO_CHUNK_BYTES=1048576 OTTO_STOCK_SHA=$IB_SHA OTTO_PATCH_SHA=$IB_SHA OTTO_GPT_SHA=$GPT_SHA
termux-usb -r -E -e $EDL/termux_usb_callback_R29E_reference.sh $USB
cat $OUT/G3_RESULT.env
grep -q "^STATUS=CLOSED_ALREADY_PATCHED_EXACT" $OUT/G3_RESULT.env || die "G3 EDL read gate did not close exact"
grep -q "^GPT_IDENTITY_VERIFIED=YES" $OUT/G3_RESULT.env || die "G3 GPT not verified"
echo "G3 PASS (EDL button + Sahara + Firehose + GPT + full init_boot_b read, no write)"
waitadb || die "G3 Android did not come back after power reset"

cat > $PKG/07_RECOVERY/RECOVERY_GATE_PASS.env <<EOF
RECOVERY_GATE=PASS
DATE=$TS
G1_ABL_FASTBOOT=PASS
G2_FASTBOOTD=PASS
G3_EDL_BUTTON_FIREHOSE_READ=PASS
INIT_BOOT_B_SHA=$IB_SHA
GPT_LBA1_SHA=$GPT_SHA
LOG_DIR=$OUT
EOF
echo "RESULT=PASS" > $OUT/RESULT.env
echo "== RECOVERY GATE PASS — stamp: 07_RECOVERY/RECOVERY_GATE_PASS.env"
