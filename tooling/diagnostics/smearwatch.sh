#!/system/bin/sh
# OTTO smear watch (2026-11-03, read-only): for 3 hours, keeps only logcat lines that tell about dropped or late video data
# (Ottocast libiDevice queue drops, CarPlay late/discarded units, key-frame requests, encoder restarts), with wall time,
# so a smear the owner sees can be matched to them. Writes /data/local/tmp/smearwatch_<HHMM>.log, then stops.
O=/data/local/tmp/smearwatch_$(date +%H%M).log
echo "$(date '+%F %T') start up=$(cut -d' ' -f1 /proc/uptime)" > $O
timeout 10800 logcat -b main,system,crash -v time -T 1 2>/dev/null | grep --line-buffered -i -E 'overfull|drop|discard|late (unit|packet|decode)|ForceKeyFrame|FKeyFrame|restart encoder|otto-a17 (stop|-->init)' >> $O
echo "$(date '+%F %T') end" >> $O
