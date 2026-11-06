#!/data/data/com.termux/files/usr/bin/bash
# OTTO EDL -> GPT -> misc BCB BACKUP ONLY. Never writes OTTO; never resets it.
set -Eeuo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
D="$HOME/storage/downloads"
[ -d "$D" ] || { echo 'Run termux-setup-storage first'; exit 1; }
OUT="$D/OTTO_EDL_BCB_READ_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/runner.log") 2>&1
trap 'echo "Runner exit=$?; files: $OUT"' EXIT
command -v termux-usb >/dev/null || { echo 'termux-usb missing'; exit 1; }
command -v python3 >/dev/null || { echo 'python3 missing'; exit 1; }
ENGINE="$BASE/otto_edl_bcb_reader.py"
[ -f "$ENGINE" ] || { echo "Missing $ENGINE"; exit 1; }
# Keep original programmer where Claude's migration package stores it.
PROGRAMMER="$BASE/../04_SCRIPTS/edl/goco7.bin"
if [ ! -f "$PROGRAMMER" ]; then
  PROGRAMMER="$BASE/04_SCRIPTS/edl/goco7.bin"
fi
if [ ! -f "$PROGRAMMER" ]; then
  echo 'goco7.bin not found; place both runner files in 07_RECOVERY/ or package root.'
  exit 1
fi
USB_LIST="$(termux-usb -l 2>&1)"
printf 'USB devices: %s\n' "$USB_LIST"
mapfile -t DEVICES < <(printf '%s\n' "$USB_LIST" | grep -oE '/dev/bus/usb/[0-9]{3}/[0-9]{3}' | sort -u)
[ "${#DEVICES[@]}" -eq 1 ] || { echo "Expected exactly one USB device, found ${#DEVICES[@]}"; exit 1; }
USB="${DEVICES[0]}"
# termux-usb -E callback receives TERMUX_USB_FD, not a generic USB permission grant.
CALLBACK_DIR="$HOME/.otto_edl_bcb"
mkdir -p "$CALLBACK_DIR"
chmod 700 "$CALLBACK_DIR"
CALLBACK="$CALLBACK_DIR/usb_callback.sh"
cat > "$CALLBACK" <<'CALL'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
: "${TERMUX_USB_FD:?No USB fd from termux-usb}"
exec python3 "$OTTO_BCB_ENGINE" "$TERMUX_USB_FD" "$OTTO_BCB_USB" "$OTTO_BCB_PROGRAMMER" "$OTTO_BCB_OUT"
CALL
chmod 700 "$CALLBACK"
export OTTO_BCB_ENGINE="$ENGINE" OTTO_BCB_USB="$USB" OTTO_BCB_PROGRAMMER="$PROGRAMMER" OTTO_BCB_OUT="$OUT"
echo "Requesting Android USB permission for $USB"
termux-usb -r -E -e "$CALLBACK" "$USB"
echo "Callback requested. Read $OUT/result.json and $OUT/runner.log for the actual outcome."
