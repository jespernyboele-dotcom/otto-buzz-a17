#!/data/data/com.termux/files/usr/bin/bash
# OTTOBUZZ bilsession — READ-ONLY opsamling fra OTTO over wireless ADB (port 29527).
# Kører på telefonen (Termux). Skriver KUN til telefonens Download-mappe. Ændrer intet på OTTO:
# ingen setprop, logcat -c, pkill, restart, install, flash eller reboot. root (su) bruges kun til at LÆSE filer.
#
# Brug:  OTTO=<ip> bash otto_bilsession_readonly.sh pull|r3|extras|drive
#   pull    henter eksisterende logs + tilstand + hashes (#1, #4, 60 Hz, R3)
#   r3      fire faser à 30 s (stille / panorer / zoom / stille) og R3-statistik pr. fase (#2)
#   extras  sockettabel (#11), touch (#6), lydformat (#12), rute-videresendelse (#8)
#   drive   hvert 30. sekund: location/GNSS, navi.log, R3-statistik, indtil Ctrl+C (#9)
set -u
MODE="${1:-}"
[ -n "${OTTO:-}" ] || { echo "Sæt OTTOs IP først:  OTTO=192.168.x.y bash $0 $MODE"; exit 2; }
S="$OTTO:29527"; A=(adb -s "$S")
BASE="/storage/emulated/0/Download/OTTO_BILSESSION_$(date +%Y%m%d)"
OUT="$BASE/${MODE}_$(date +%H%M%S)"; mkdir -p "$OUT"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$OUT/session.log"; }
sh_ro() { "${A[@]}" exec-out "$1" 2>/dev/null; }                       # shell-bruger, læsning
su_ro() { "${A[@]}" exec-out "su -c '$1'" 2>/dev/null; }               # root, kun læsning
grab()  { su_ro "cat $1" > "$OUT/$2"; [ -s "$OUT/$2" ] && say "hentet $1 ($(stat -c %s "$OUT/$2") B)" || { rm -f "$OUT/$2"; say "findes ikke/tom: $1"; }; }
uptime_otto() { sh_ro "cat /proc/uptime" | cut -d' ' -f1; }
finish() { say "$1  ->  $OUT"; (cd "$OUT" && sha256sum -- * 2>/dev/null | grep -v ' SHA256SUMS.txt$' > SHA256SUMS.txt); }   # log først, så session.log er med i summen

adb connect "$S" >/dev/null 2>&1
"${A[@]}" get-state 2>/dev/null | grep -q device || { echo "Ingen forbindelse til $S (samme Wi-Fi? OTTO tændt?)"; exit 3; }
say "mode=$MODE otto=$S uptime=$(uptime_otto)s boot_id=$(sh_ro 'cat /proc/sys/kernel/random/boot_id')"

state() {
  { echo "== props"; for p in ro.boot.slot_suffix ro.build.fingerprint sys.ly.protocol sys.usb.config debug.sf.enable_hwc_vds persist.ly.hugps.enable; do echo "$p=$(sh_ro "getprop $p")"; done
    echo "== uptime"; sh_ro "cat /proc/uptime"
    echo "== render rate"; sh_ro "dumpsys display" | grep -m5 -E 'renderFrameRate|fps='
    echo "== processes"; sh_ro "ps -A -o PID,STIME,NAME" | grep -E 'lylink|lyscr|mdnsd|com.ap.play|mylink|otto|app_process' ; } > "$OUT/state.txt"
  { echo "init_boot_b expected 11948ad86ba948ba4a898a8a7ec1ae5594c5e424842393fa5937b4434ad36880"
    echo "init_boot_b actual   $(su_ro 'sha256sum /dev/block/by-name/init_boot_b' | cut -d' ' -f1)"
    echo "libsdmcore expected  48b22c95662d3e6a54783c9a7c9d49acce0b5843b372512c64cf16488275e9df"
    echo "libsdmcore actual    $(su_ro 'sha256sum /vendor/lib64/libsdmcore.so' | cut -d' ' -f1)"
    echo "screenrecord R3 exp. 6b38d2dfe5c6ff63a350f6c79d2c826fe5af6e4d1eb866e2239331932c2903c0"
    echo "screenrecord actual  $(su_ro 'sha256sum /system/lib/libscreenrecord.so' | cut -d' ' -f1)"
    echo "recorder_bitrate     $(su_ro 'cat /data/adb/otto/config/recorder_bitrate')"; } > "$OUT/hashes.txt"
  say "tilstand og hashes gemt"; cat "$OUT/hashes.txt"
}

r3stats() {   # $1 = fasegrænser "fase start_s slut_s" (OTTO uptime); $2 = recorder.log
  # Linjeformat (R3): "<sek>.<ms> otto-r3 stats <dt> ms: <kbit> kbit/s real=<n> synth=<n>"; tiden er vinduets slutning.
  # Kun 10-s vinduer, der ligger HELT inde i en fase, tælles med (portabel awk, ingen gawk-udvidelser).
  awk 'FNR==NR { n++; ph[n]=$1; a[n]=$2; b[n]=$3; next }
       /otto-r3 stats/ { t=$1+0; dt=0; kbit=0; re=-1; sy=-1
         for (k=1;k<=NF;k++) { if ($k=="stats") dt=$(k+1)+0; if ($k=="kbit/s") kbit=$(k-1)+0
                               if ($k ~ /^real=/) { re=substr($k,6)+0 } if ($k ~ /^synth=/) { sy=substr($k,7)+0 } }
         if (dt<=0 || re<0) next
         for (i=1;i<=n;i++) if (t-dt/1000 >= a[i] && t <= b[i]) { ms[i]+=dt; kb[i]+=kbit*dt; r[i]+=re; s[i]+=sy; w[i]++ } }
       END { for (i=1;i<=n;i++) if (ms[i]>0) printf "%-12s vinduer=%d  real=%.1f/s  synth=%.1f/s  ~%d kbit/s\n", ph[i], w[i], r[i]*1000/ms[i], s[i]*1000/ms[i], kb[i]/ms[i];
             else printf "%-12s ingen fulde 10-s vinduer (fase for kort eller ingen R3-linjer)\n", ph[i] }' "$1" "$2"
}

case "$MODE" in
pull)
  state
  grab /data/adb/otto/logs/recorder.log recorder.log
  grab /data/adb/otto/logs/hwc_vds.log hwc_vds.log
  grab /data/adb/otto/logs/rec_test.log rec_test.log
  for f in $(su_ro 'ls /data/adb/otto_navi/navi.log* 2>/dev/null' | tr -d '\r'); do grab "$f" "$(basename "$f")"; done
  for f in $(su_ro 'ls /data/local/tmp/otto_car_car1.txt /data/local/tmp/otto_drive_1025_0915.txt /data/local/tmp/otto_postboot_verify_20261025_2005* 2>/dev/null' | tr -d '\r'); do grab "$f" "$(basename "$f")"; done
  grab /metadata/otto/firstboot.log firstboot.log
  finish PULL_DONE ;;
r3)
  state; : > "$OUT/phases.txt"
  for ph in stille panorering zoom stille2; do
    case $ph in stille|stille2) msg="Rør IKKE skærmen";; panorering) msg="Træk kortet frem og tilbage hele tiden";; zoom) msg="Dobbelttryk / tryk-hold-træk for at zoome";; esac
    read -r -p ">> Fase '$ph' (30 s): $msg. Tryk Enter for at starte." _
    t0=$(uptime_otto); say "start $ph uptime=$t0"; sleep 30; t1=$(uptime_otto); say "slut  $ph uptime=$t1"
    echo "$ph $t0 $t1" >> "$OUT/phases.txt"
  done
  sleep 12; grab /data/adb/otto/logs/recorder.log recorder.log
  r3stats "$OUT/phases.txt" "$OUT/recorder.log" | tee "$OUT/R3_RESULTAT.txt"
  finish R3_DONE ;;
extras)
  state
  su_ro 'ss -tuanp' > "$OUT/sockets_tuanp.txt"; say "sockettabel gemt (#11)"
  su_ro 'ls -l /proc/$(pidof lylinkservice)/fd' | grep -E 'ly_touch|socket' > "$OUT/lylink_fd.txt"; say "lylinkservice fd-liste gemt (#6)"
  dev=$(sh_ro "getevent -pl" | awk '/^add device/{d=$4} /name:.*LY Touchscreen/{print d; exit}')
  if [ -n "$dev" ]; then read -r -p ">> Tryk Enter, og tryk derefter ÉN gang på CarPlay-skærmen inden for 5 s." _
    sh_ro "timeout 5 getevent -lt $dev" > "$OUT/getevent_ly_touch.txt"; say "getevent fra $dev gemt (#6)"
  else say "LY Touchscreen ikke fundet i getevent -pl"; fi
  read -r -p ">> Start musik (Spotify). Tryk Enter når den spiller; der ventes 20 s." _; sleep 20
  sh_ro "logcat -d -b all" | grep -aE 'SetupMainAudio|audioFormat|AudioPlayerCreate|GetHUAudioFormat|setPCMDirectMode|peerMainAudioRecvPort' > "$OUT/audio_format.txt"; say "lydlinjer: $(wc -l < "$OUT/audio_format.txt") (#12)"
  read -r -p ">> Start en rute i Maps. Tryk Enter når den kører; der ventes 30 s." _; sleep 30
  sh_ro "logcat -d -b all" | grep -aE 'SendiAP2RawDataToHu|startPassRawData|pass raw data|WriteiAPData' > "$OUT/iap2_forward.txt"; say "videresendelseslinjer: $(wc -l < "$OUT/iap2_forward.txt") (#8)"
  su_ro 'tail -n 60 /data/adb/otto_navi/navi.log' > "$OUT/navi_tail.txt"
  finish EXTRAS_DONE ;;
drive)
  state; i=0; trap 'finish DRIVE_DONE; exit 0' INT
  say "Optager hvert 30. sekund. Ctrl+C når du er parkeret efter turen."
  while :; do
    i=$((i+1)); n=$(printf %04d $i); u=$(uptime_otto)
    { echo "## $(date '+%F %T') uptime=$u"; sh_ro "dumpsys location"; } > "$OUT/location_$n.txt"
    su_ro 'tail -n 40 /data/adb/otto_navi/navi.log' > "$OUT/navi_$n.txt"
    su_ro 'grep "otto-r3 stats" /data/adb/otto/logs/recorder.log | tail -n 3' > "$OUT/r3_$n.txt"
    echo "$(date '+%T') uptime=$u snapshot=$n" >> "$OUT/session.log"
    sleep 30
  done ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
