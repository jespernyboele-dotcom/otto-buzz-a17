#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
FD="${TERMUX_USB_FD:-}"
USBP="${OTTO_TERMUX_USB_PATH:-}"
[[ "$FD" =~ ^[0-9]+$ ]]
[[ "$USBP" == /dev/bus/usb/* ]]
exec python3 "$OTTO_ENGINE" "$FD" "$USBP" "$OTTO_PROGRAMMER" "$OTTO_PATCHED" "$OTTO_STOCK_REF" \
  "$OTTO_OUTENV" "$OTTO_RAWLOG" "$OTTO_EVIDENCE" "$OTTO_LEDGER" \
  "$OTTO_FIRST_LBA" "$OTTO_LAST_LBA" "$OTTO_TARGET_BYTES" "$OTTO_CHUNK_BYTES" \
  "$OTTO_STOCK_SHA" "$OTTO_PATCH_SHA" "$OTTO_GPT_SHA"
