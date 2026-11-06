#!/bin/bash
# Parked test: feed fake car NMEA into one car GPS jar on OTTO while Maps navigates, screenshot, clean up.
# usage: OTTO_ADB=<OTTO_IP>:29527 run_feed.sh p5|p6 SECONDS   (first: adb push the jar to /data/local/tmp/<p5|p6>.jar,
#        and start a Maps route on OTTO; car GPS from the car must be silent, e.g. parked with the car off)
set -u
D=${OTTO_ADB:?set OTTO_ADB=<OTTO_IP>:29527}; S=$(cd "$(dirname "$0")" && pwd); OUT=${OUT:-.}
J=$1; N=$2
adb -s $D shell "su -c 'rm -f /data/local/tmp/nmea.fifo /data/local/tmp/$J.stop; mkfifo /data/local/tmp/nmea.fifo; chmod 666 /data/local/tmp/nmea.fifo'"
adb -s $D shell "su -c 'CLASSPATH=/data/local/tmp/$J.jar nohup app_process / OttoCarGps --device=/data/local/tmp/nmea.fifo --identity=root --stop-file=/data/local/tmp/$J.stop > /data/local/tmp/$J.log 2>&1 &'"
sleep 2
python3 -I "$S/nmea_gen.py" $N ${START_LAT:-56.0} ${START_LON:-9.0} | adb -s $D shell "su -c 'cat > /data/local/tmp/nmea.fifo'" &
FEED=$!
sleep $((N - 15))
adb -s $D exec-out "su -c 'screencap -d 4630946917876887939 -p'" > $OUT/feed_$J.png
adb -s $D shell "su -c 'dumpsys location 2>/dev/null | grep -m1 \"last location=Location\[gps\"'"
wait $FEED
adb -s $D shell "su -c 'touch /data/local/tmp/$J.stop; sleep 3; for p in \$(pidof app_process); do grep -q nmea.fifo /proc/\$p/cmdline 2>/dev/null && kill \$p; done; cmd location providers remove-test-provider gps 2>/dev/null; cat /data/local/tmp/$J.log | tail -5'"
