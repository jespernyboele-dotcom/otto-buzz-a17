#!/system/bin/sh
# OTTO car test (run as root on OTTO in the car, CarPlay running): chain state, NAVI, car GPS, then load,
# jank and temperature with the stream active. Read-only except input swipes and gfxinfo resets.
# Usage: sh car_measure.sh <label>
L=${1:-car}
O=/data/local/tmp/otto_car_$L.txt
MAPS=com.google.android.apps.maps
temps() { for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); case "$t" in *cpu*|*gpu*|*skin*|*xo*|*pa*) echo "$t=$(($(cat $z/temp 2>/dev/null)/1000))C";; esac; done | tr '\n' ' '; echo; }
{
echo "== $L $(date) up=$(cut -d. -f1 /proc/uptime)s"
echo "== CarPlay chain"
echo "protocol=$(getprop sys.ly.protocol) usb=$(getprop sys.usb.config) verify=$(getprop ly.verify.state)"
echo "lylink=$(pidof lylinkservice) lyscr=$(pidof lyscrservice) scrcpy=$(pgrep -f com.genymobile.scrcpy | tr '\n' ' ')"
echo "usb0=$(ip -6 -o addr show usb0 2>/dev/null | head -1 | awk '{print $4}')"
echo "HU sockets: $(ss -tn 2>/dev/null | grep -c -E ':(7000|6030|5001) ')"
echo "displays (virtual = CarPlay recorder):"; dumpsys display | grep -E "mDisplayId=|mName=|VIRTUAL" | head -12
echo "== NAVI"
echo "otto_rgid=$(pidof otto_rgid) hus5277=$(ss -lnt | grep -c ':5277 ')"
tail -n 5 /data/adb/otto_navi/*.log 2>/dev/null
echo "== car GPS"
echo "hugps.enable=$(getprop persist.ly.hugps.enable) cargps_dev=$(ls -l /dev/cargps_serial 2>&1)"
dumpsys location | grep -m3 -E "last location=Location\[(gps|fused)"
echo "== temperatures (start)"; temps
echo "== CPU top (stream idle)"; top -b -n 1 -m 10 | tail -11
dumpsys gfxinfo $MAPS reset >/dev/null; dumpsys gfxinfo com.android.settings reset >/dev/null
echo "== Maps pan (Home), 20 s"
input keyevent HOME; sleep 3
i=0; while [ $i -lt 10 ]; do input swipe 300 420 900 420 600; input swipe 900 420 300 420 600; i=$((i+1)); done
dumpsys gfxinfo $MAPS | grep -E "Total frames|Janky frames|90th|95th|99th" | head -5
echo "== Settings scroll (same as the A13/A17 benchmark), 16 s"
am start -a android.settings.SETTINGS >/dev/null 2>&1; sleep 3; dumpsys gfxinfo com.android.settings reset >/dev/null
i=0; while [ $i -lt 6 ]; do input swipe 960 700 960 160 650; sleep 0.25; input swipe 960 160 960 700 650; sleep 0.25; i=$((i+1)); done
dumpsys gfxinfo com.android.settings | grep -E "Total frames|Janky frames|90th|95th|99th" | head -5
input keyevent HOME
echo "== composition"; dumpsys SurfaceFlinger | grep -c " CLIENT" | sed 's/^/CLIENT layers: /'
echo "== CPU top (after load)"; top -b -n 1 -m 10 | tail -11
echo "== temperatures (end)"; temps
} > $O 2>&1
cat $O
