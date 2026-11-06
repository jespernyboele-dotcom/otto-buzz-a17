#!/data/data/com.termux/files/usr/bin/bash
# Standalone G3 extracted from original recovery_gate_READ_ONLY.sh.
# Only Termux USB EDL, no ADB, no fastboot, no partition writes.
set -Euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd)
TS=$(date +%Y%m%d_%H%M%S)
OUT="$PKG/05_LOGS/recovery_G3_only_$TS"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/G3.log") 2>&1
EDL="$PKG/04_SCRIPTS/edl"
GPT_SHA=712ca75b50cb24cec9e9a7beaf3a2bdeb1871d3a0a7276fad5243456edf1d181
IB="$PKG/01_BACKUPS/boot_chain/init_boot_b.img"
die(){ echo "G3 FAIL: $*"; printf 'RESULT=FAIL\nREASON=%s\n' "$*" > "$OUT/RESULT.env"; exit 1; }
command -v termux-usb >/dev/null || die 'termux-usb missing'
[ -f "$IB" ] || die 'init_boot_b backup missing'
[ -f "$EDL/root_reader_R29E_STRICT_READ_ONLY.py" ] || die 'read-only reader missing'
[ -f "$EDL/goco7.bin" ] || die 'Firehose programmer missing'
[ -f "$EDL/termux_usb_callback_R29E_reference.sh" ] || die 'USB callback missing'
IB_SHA=$(sha256sum "$IB" | cut -d' ' -f1)
echo 'G3: Sluk OTTO, hold fysisk EDL-knap inde og taend. Skaermen skal vaere sort.'
read -r -p 'Er OTTO i EDL? [ja/nej] ' a
[ "$a" = ja ] || die 'operator aborted'
USB=''
for i in $(seq 1 40); do
  mapfile -t U < <(termux-usb -l 2>/dev/null | grep -o '/dev/bus/usb/[0-9]\{3\}/[0-9]\{3\}' | sort -u)
  if [ "${#U[@]}" -eq 1 ]; then USB="${U[0]}"; break; fi
  sleep 1
done
[ -n "$USB" ] || die 'expected exactly one USB device in EDL'
mkdir -p "$OUT/G3_firehose"
export OTTO_TERMUX_USB_PATH="$USB" OTTO_ENGINE="$EDL/root_reader_R29E_STRICT_READ_ONLY.py" OTTO_PROGRAMMER="$EDL/goco7.bin" \
  OTTO_PATCHED="$IB" OTTO_STOCK_REF="$IB" OTTO_OUTENV="$OUT/G3_RESULT.env" OTTO_RAWLOG="$OUT/G3_raw.hexlog" \
  OTTO_EVIDENCE="$OUT/G3_firehose" OTTO_LEDGER="$OUT/G3_ledger.tsv" OTTO_FIRST_LBA=16646160 OTTO_LAST_LBA=16662543 \
  OTTO_TARGET_BYTES=8388608 OTTO_CHUNK_BYTES=1048576 OTTO_STOCK_SHA="$IB_SHA" OTTO_PATCH_SHA="$IB_SHA" OTTO_GPT_SHA="$GPT_SHA"
termux-usb -r -E -e "$HOME/otto_edl_callback.sh" "$USB" || die 'Termux USB callback failed'
[ -f "$OUT/G3_RESULT.env" ] || die 'reader did not create result'
cat "$OUT/G3_RESULT.env"
grep -qx 'STATUS=CLOSED_ALREADY_PATCHED_EXACT' "$OUT/G3_RESULT.env" || die 'exact content verification failed'
grep -qx 'ROOT_WRITE_PERFORMED=NO' "$OUT/G3_RESULT.env" || die 'reader reported a write'
grep -qx 'POWER_RESET_SENT=YES' "$OUT/G3_RESULT.env" || die 'power reset not confirmed'
grep -qx 'GPT_IDENTITY_VERIFIED=YES' "$OUT/G3_RESULT.env" || die 'GPT verification failed'
cat > "$PKG/07_RECOVERY/G3_ONLY_PASS.env" <<STAMP
G3_EDL_BUTTON_FIREHOSE_READ=PASS
DATE=$TS
INIT_BOOT_B_SHA=$IB_SHA
GPT_LBA1_SHA=$GPT_SHA
LOG_DIR=$OUT
STAMP
echo 'RESULT=PASS' > "$OUT/RESULT.env"
echo 'G3 PASS — evidence saved. Full recovery preflight stamp NOT created.'
