#!/system/bin/sh
# OTTO Recorder R3 test control (root on OTTO).
#   sh otto_rec_test.sh status         what is loaded, configured bitrate, last stats
#   sh otto_rec_test.sh set <bits/s>   e.g. 8000000; takes effect at the next boot (or 'apply')
#   sh otto_rec_test.sh apply          bind now + restart lyscrservice (bench only: drops a running projection)
#   sh otto_rec_test.sh off            remove the boot hook + config; reboot to return to the image's library
C=/data/adb/otto/config/recorder_bitrate; H=/data/adb/post-fs-data.d/90-otto-rec-test.sh; L=/data/adb/otto/rec_test/libscreenrecord.so
case "$1" in
  status)
    echo "hook: $([ -f $H ] && echo installed || echo absent)   bitrate file: $(cat $C 2>/dev/null || echo none)"
    echo "loaded lib sha: $(sha256sum /system/lib/libscreenrecord.so | cut -c1-16)  (R3 test = $(sha256sum $L 2>/dev/null | cut -c1-16))"
    tail -3 /data/adb/otto/logs/rec_test.log 2>/dev/null
    ps -A -o ARGS | grep -o 'scid=[0-9a-f]* .*video_bit_rate=[0-9]*' | sed 's/ log_level.*video_bit_rate/ ... video_bit_rate/'
    logcat -d -s ScreenRecord | grep -E 'otto-r3|init:' | tail -8 ;;
  set)
    case "$2" in ''|*[!0-9]*) echo "usage: set <bits/s>"; exit 1;; esac
    [ "$2" -ge 1000000 ] && [ "$2" -le 40000000 ] || { echo "1000000..40000000 only"; exit 1; }
    mkdir -p /data/adb/otto/config; echo "$2" > $C; echo "bitrate $2 set; reboot (or 'apply' on the bench)" ;;
  apply)
    grep -q " /system/lib/libscreenrecord.so " /proc/mounts || mount -o bind $L /system/lib/libscreenrecord.so
    pkill -f lyscrservice; sleep 1
    nohup nice -n -20 /system/bin/lyscrservice >/dev/null 2>&1 &
    echo "lyscrservice restarted with $(sha256sum /system/lib/libscreenrecord.so | cut -c1-16)" ;;
  off)
    rm -f $H $C; echo "test hook removed; reboot to load the image's library again" ;;
  *) sed -n '2,7p' $0 ;;
esac
