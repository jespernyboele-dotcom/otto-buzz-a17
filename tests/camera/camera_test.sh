#!/bin/bash
# OTTO camera benchmark D (2026-11-06). Runs on the Pixel while the owner films the MIB4. Usage: bash camera_test.sh <otto-ip>
# Phases (device uptime logged in actions.tsv): Home 5 s -> 60 fps clip 60 s -> Maps pan 30 s -> 5x Podimo/Home -> Home.
# Before: pushes the 60 fps test clip and grants Just Player media read; starts the smear watch. After: removes the clip and
# revokes the permission, pulls the smear watch log. Nothing else on OTTO changes.
set -u
IP=${1:?otto ip}; S=$IP:29527
HERE=$(cd "$(dirname "$0")" && pwd); RUN=$HERE/camera_run_$(date +%H%M%S); mkdir -p "$RUN"
CLIP=/storage/emulated/0/Download/OTTOBUZZ_MIB4_UNATTENDED_FPS_20261031/media/otto_fps_60fps_1920x840_90s.mp4
DEV=/sdcard/Movies/otto_fps_test; PL=com.brouken.player
sh_() { timeout 30 adb -s $S exec-out "$1" 2>/dev/null; }
up() { sh_ "cut -d' ' -f1 /proc/uptime" | tr -d '\r\n '; }
act() { echo -e "$(date +%T)\t$(up)\t$1" | tee -a "$RUN/actions.tsv"; }

adb connect $S >/dev/null 2>&1
sh_ "su -c 'grep -a \"first frame delivered\" /data/adb/otto/logs/recorder.log | tail -1'" | grep -q first || { echo "STOP: no CarPlay picture this boot"; exit 1; }
sh_ "mkdir -p $DEV"; adb -s $S push "$CLIP" $DEV/clip60.mp4 >/dev/null || { echo "STOP: push failed"; exit 1; }
sh_ "pm grant $PL android.permission.READ_MEDIA_VIDEO"
adb -s $S push "$HERE/../../tooling/diagnostics/smearwatch.sh" /data/local/tmp/smearwatch.sh >/dev/null
sh_ "su -c 'setsid nohup sh /data/local/tmp/smearwatch.sh >/dev/null 2>&1 < /dev/null &'"
sh_ "input keyevent KEYCODE_HOME"
echo; echo ">>> START OPTAGELSEN NU (sekvensen starter om 10 s)"; sleep 10
act home_start; sleep 5
act clip60_start; sh_ "am start -S -a android.intent.action.VIEW -d file://$DEV/clip60.mp4 -t video/mp4 -n $PL/.PlayerActivity" >/dev/null; sleep 60
act clip60_end; sh_ "input keyevent KEYCODE_HOME"; sleep 5
act pan_start; for i in $(seq 1 8); do sh_ "input swipe 900 420 400 420 400"; sleep 1; sh_ "input swipe 400 420 900 420 400"; sleep 1; done; act pan_end
for i in 1 2 3 4 5; do act "podimo_$i"; sh_ "monkey -p com.podimo -c android.intent.category.LAUNCHER 1" >/dev/null; sleep 5; act "home_$i"; sh_ "input keyevent KEYCODE_HOME"; sleep 5; done
act end; echo ">>> STOP OPTAGELSEN"
sh_ "am force-stop $PL; rm -r $DEV; pm revoke $PL android.permission.READ_MEDIA_VIDEO"
sleep 2; L=$(sh_ "su -c 'ls -t /data/local/tmp/smearwatch_*.log | head -1'" | tr -d '\r'); [ -n "$L" ] && sh_ "su -c 'cat $L'" > "$RUN/smearwatch.log"
echo "done: $RUN"
