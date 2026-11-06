#!/system/bin/sh
# OTTO F23 (2026-10-31): apply / roll back the background diet now (the final build does the same in otto_firstboot.sh).
# Run as root on OTTO: sh f23_background_diet.sh measure|apply|rollback
DIS="com.google.android.gm com.android.calendar com.google.android.apps.docs com.google.android.contacts com.google.android.dialer
     com.google.android.videos com.google.android.feedback com.google.android.printservice.recommendation
     com.google.android.avatarpicker com.google.android.cellbroadcastreceiver com.google.android.tag"
BG="com.google.android.youtube com.netflix.mediaclient dk.tv2.tv2play dk.dr.webplayer"
L=/data/adb/otto/logs/f23.log
measure() {
  echo "== $(date '+%F %T') up=$(cut -d' ' -f1 /proc/uptime)"
  grep -E 'MemTotal|MemFree|MemAvailable|Cached:|SwapTotal|SwapFree' /proc/meminfo
  cat /proc/swaps
  dumpsys meminfo -s 2>/dev/null | sed -n '/Total PSS by process/,/Total PSS by OOM/p' | head -40
  ps -A -o PID,RSS,NAME | sort -k2 -n -r | head -25
}
case "$1" in
  measure) measure | tee -a $L ;;
  apply)
    for p in $DIS; do pm disable-user --user 0 $p >/dev/null 2>&1 && echo "disabled $p"; done | tee -a $L
    for p in $BG; do pm path $p >/dev/null 2>&1 && { cmd appops set $p RUN_ANY_IN_BACKGROUND ignore; am set-standby-bucket $p restricted; am force-stop $p; echo "background-restricted $p"; }; done | tee -a $L ;;
  rollback)
    for p in $DIS; do pm enable --user 0 $p >/dev/null 2>&1 && echo "enabled $p"; done | tee -a $L
    for p in $BG; do pm path $p >/dev/null 2>&1 && { cmd appops set $p RUN_ANY_IN_BACKGROUND allow; am set-standby-bucket $p active; echo "background-allowed $p"; }; done | tee -a $L ;;
  *) echo "usage: $0 measure|apply|rollback" ;;
esac
