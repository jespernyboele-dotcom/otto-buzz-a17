#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# OTTO R119 — streaming super writer runner (Termux, no proot, no QIL)
#
# Chain: Termux -> termux-usb (FD) -> python3 otto_r119_super_writer.py
#        -> Sahara -> goco7 -> Firehose 1 MiB stop-and-wait <program> -> super
#
# No disk unpack: the sparse image is expanded 1 MiB at a time in memory.
# Resumable: R119_LEDGER.txt holds NEXT_CHUNK; a lost session is retried
# automatically (new termux-usb grant) and continues where it stopped.
#
# SAFETY: read-only preflight unless OTTO_R119_CONFIRM=FLASH_SUPER.
#         No power reset is ever sent.
# =============================================================================
set -u
DL=/data/data/com.termux/files/home/storage/downloads
HERE="$DL/qfil/R119_STREAM_WRITER"
WRITER="$HERE/otto_r119_super_writer.py"
IMAGE="${OTTO_R119_IMAGE:-a17}"   # a17 = A17 sparse, a13 = original A13 backup
GOCO="$DL/OTTO_A17_PERMANENT_MIGRATION/04_SCRIPTS/edl/goco7.bin"
case "$IMAGE" in
  a17) SIMG="$DL/qfil/otto/OTTO_A17_super.simg" ;;
  a13) SIMG="$DL/OTTO_A17_PERMANENT_MIGRATION/01_BACKUPS/a13_super/OTTO_A13_super_mmcblk0p19_raw.img.gz" ;;
  *) echo "FATAL: OTTO_R119_IMAGE must be a17 or a13"; exit 2 ;;
esac
LEDGER="$HERE/R119_LEDGER_${IMAGE}.txt"   # separate resume state per image
MAX_SESSIONS="${OTTO_R119_MAX_SESSIONS:-40}"
CONFIRM="${OTTO_R119_CONFIRM:-}"
# OTTO_R119_MODE=inspect: read-only eMMC inspection (never writes).
[ "${OTTO_R119_MODE:-}" = inspect ] && CONFIRM=INSPECT
[ "${OTTO_R119_MODE:-}" = status ] && CONFIRM=STATUS     # read-only: misc + slot bits
# OTTO_R119_MODE=misc-fastboot|misc-clear: set/clear the misc boot command.
# Dry-run unless OTTO_R119_CONFIRM=WRITE_MISC. Never touches super.
MISC_WRITE=NO
case "${OTTO_R119_MODE:-}" in
  misc-fastboot|misc-clear)
    [ "$CONFIRM" = WRITE_MISC ] && MISC_WRITE=YES
    [ "${OTTO_R119_MODE}" = misc-fastboot ] && CONFIRM=MISC_FASTBOOT || CONFIRM=MISC_CLEAR ;;
esac

OUT="$HERE/RUN_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT" || exit 2
LOG="$OUT/R119_RUN.log"
say(){ printf '%s\n' "$*" | tee -a "$LOG"; }

say "=== OTTO R119 STREAM WRITER ==="
say "IMAGE=$IMAGE ($SIMG)"
say "START=$(date -Is) MODE=$(case "$CONFIRM" in FLASH_SUPER) echo LIVE_FLASH;; INSPECT) echo INSPECT_READ_ONLY;; MISC_*) echo "$CONFIRM write=$MISC_WRITE";; *) echo PREFLIGHT_ONLY;; esac)"
for t in termux-usb python3; do command -v "$t" >/dev/null || { say "FATAL: missing $t"; exit 3; }; done
[ -f "$WRITER" ] && [ -f "$GOCO" ] && [ -f "$SIMG" ] || { say "FATAL: missing writer/goco7/simg"; exit 4; }
say "LEDGER=$(grep -s '^NEXT_CHUNK=' "$LEDGER" || echo 'NEXT_CHUNK=0 (new)')"

# Shared storage is mounted noexec: the callback must live under $HOME.
WORK="$(mktemp -d "$HOME/.otto_r119.XXXXXX")" || exit 8
trap 'rm -rf "$WORK"' EXIT
CB="$WORK/callback.sh"
cat > "$CB" <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
FD="${TERMUX_USB_FD:-}"
case "$FD" in ''|*[!0-9]*) echo 21 > "$R119_RC"; exit 21;; esac
python3 -u "$R119_WRITER" run "$FD" "$R119_GOCO" "$R119_SIMG" "$R119_LEDGER" "$R119_OUT" "$R119_CONFIRM" 2>&1 | tee -a "$R119_LOG"
echo "${PIPESTATUS[0]}" > "$R119_RC"
SH
chmod 700 "$CB"
export R119_WRITER="$WRITER" R119_GOCO="$GOCO" R119_SIMG="$SIMG" R119_LEDGER="$LEDGER" \
       R119_MISC_WRITE="$MISC_WRITE" R119_OUT="$OUT" R119_CONFIRM="$CONFIRM" R119_LOG="$LOG" R119_RC="$OUT/rc" \
       R119_A17="$DL/qfil/otto/OTTO_A17_super.simg" \
       R119_A13="$DL/OTTO_A17_PERMANENT_MIGRATION/01_BACKUPS/a13_super/OTTO_A13_super_mmcblk0p19_raw.img.gz" \
       R119_BACKUPS="$DL/OTTO_A17_PERMANENT_MIGRATION/01_BACKUPS/boot_chain"

find_dev(){
  for i in $(seq 1 300); do   # up to 10 min: time to re-enter EDL by hand
    DEV="$(termux-usb -l 2>/dev/null | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' | sort -u)"
    [ "$(printf '%s\n' "$DEV" | grep -c .)" -eq 1 ] && return 0
    sleep 2
  done
  return 1
}

RC=99
for s in $(seq 1 "$MAX_SESSIONS"); do
  say "--- SESSION $s/$MAX_SESSIONS  $(grep -s '^NEXT_CHUNK=' "$LEDGER" || echo NEXT_CHUNK=0) ---"
  find_dev || { say "FATAL: no single USB device found (is OTTO in EDL 9008?)"; RC=7; break; }
  say "USB_DEVICE=$DEV"
  termux-usb -r "$DEV" || { say "USB permission denied"; RC=9; break; }
  rm -f "$OUT/rc"
  termux-usb -E -e "$CB" "$DEV"
  RC="$(cat "$OUT/rc" 2>/dev/null || echo 97)"
  say "SESSION_RC=$RC"
  case "$RC" in
    0)  say "RESULT=FLASH_PASS"; break ;;
    10) say "RESULT=PREFLIGHT_OK"; break ;;
    11) say "RESULT=INSPECT_DONE report=$OUT/R119_INSPECT_REPORT.txt"; break ;;
    12) say "RESULT=MISC_DRY_RUN_OK"; break ;;
    13) say "RESULT=MISC_WRITTEN_AND_VERIFIED"; break ;;
    14) say "RESULT=STATUS_DONE"; break ;;
    97) say "RESULT=CALLBACK_DID_NOT_RUN (nothing written) - stopping"; break ;;
    20|98) say "session lost -> put OTTO in EDL again (waiting up to 10 min), then resuming"; sleep 8 ;;
    *)  say "RESULT=HARD_STOP rc=$RC (see log)"; break ;;
  esac
done
say "END=$(date -Is) FINAL_RC=$RC"
say "REPORT_DIR=$OUT"
