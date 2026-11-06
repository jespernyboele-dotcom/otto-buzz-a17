#!/system/bin/sh
# OTTO NAVI supervisor: Android Auto (Gearhead) navigation -> native iAP2 route guidance.
# ONE pipe:   OttoAaNav (client + converter)  --event lines-->  otto_rgid (engine + OEM pass-through socket)
#
# It never touches the old notification bridge, the OEM CarPlay services or any property. It only sends when ALL hold:
#   - its own stop file  $D/disable  does not exist
#   - the old bridge is paused by ITS stop file and its process is gone     (one sender on the OEM socket, never two)
#   - the box is in the CarPlay production mode (sys.ly.protocol = rcp)
# These are checked before every start and every $POLL seconds while the pipe runs; a violation ends the pipe with a
# route end. Stop:  touch $D/disable     Roll back: stop this service, then  rm -f $OLD/disable ; start otto_nav_bridge
#
# P5 (facts from the first start on the device):
#   - Android Auto binds the navigation app only when a session is created. If Maps starts later, that session never gets
#     navigation data, so the pipe is restarted when the Maps process appears or changes.
#   - A head unit server that accepts connections but never answers (client exit code 11) is stopped; the next round starts it.
#   - config  route=A|B  (+ feed_ms=1000|500|286): TEST ONLY, the client feeds positions from $D/routes/<name>.txt to
#     Android Auto so that Maps follows a recorded route while the car stands still. Default none.
#   - config  mode=dry  runs the engine without any socket (it prints what it would send); default is live.
#
# 0.6 (release preparation, 2026-10-17):
#   - route=, feed_ms= and mode= are TEST options: they are read only while the file $D/test_options exists.
#   - Receiver rules come from the profile file $D/profiles/<receiver>.conf (keys confirm_first, startup_clean,
#     rbt_no_number, left_off_ramp). Without a file the 0.5 behaviour of that receiver applies.
#   - config full_circle_ccw=plus180|minus180: angle of a counter-clockwise full circle (open decision R4.1 R-3); default plus180.
#   - Port 5277 (Android Auto head unit server) is closed for every interface except loopback (two rules in oem_in,
#     addendum 6); config harden_5277=on|off, default on. The rules live until the next boot.
#   - Car GPS (decision 2026-10-16): OttoCarGps feeds the "gps" provider from the car while the car sends fresh fixes and
#     removes it otherwise (OTTO GNSS takes over). It needs persist.ly.hugps.enable=1 (an installation step, never set here).
#     config car_gps=on|off, default on. It runs beside the navigation pipe and is stopped with a stop file (app_process
#     does not run shutdown hooks on SIGTERM, P4); any "gps" test provider left behind is removed here as well.
#
# The OTTO_NAVI_* variables exist for the offline tests only; a device never sets them.
D=${OTTO_NAVI_DIR:-/data/adb/otto_navi}
OLD=${OTTO_NAVI_OLD_BRIDGE_DIR:-/data/adb/otto_nav_bridge}
BIN=${OTTO_NAVI_BIN_DIR:-/data/adb/otto_navi/bin}
POLL=${OTTO_NAVI_POLL_S:-15}
WAIT=${OTTO_NAVI_WAIT_S:-30}
RESTART=${OTTO_NAVI_RESTART_S:-10}
LOG=$D/navi.log
GPSSTOP=$D/cargps.stop
FIFO=$D/events.fifo
MAXLOG=262144
HUS=com.google.android.projection.gearhead/.companion.DeveloperHeadUnitNetworkService
MAPS=com.google.android.apps.maps
PROJ=com.google.android.projection.gearhead:projection

mkdir -p "$D" 2>/dev/null
rot() { [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt $MAXLOG ] && mv -f "$LOG" "$LOG.1"; }
log() { echo "$(date '+%m-%d %H:%M:%S') supervisor: $*" >> "$LOG"; }
cfg() {                                   # cfg KEY DEFAULT ALLOWED...   ->  the configured value if it is one of ALLOWED, else DEFAULT
    k=$1; def=$2; shift 2
    v=$(sed -n "s/^$k=//p" "$D/config" 2>/dev/null | head -n 1)
    for a in "$@"; do [ "$v" = "$a" ] && { echo "$v"; return; }; done
    [ -n "$v" ] && log "config: $k=$v is not valid, using $def"
    echo "$def"
}
blocked() {                               # prints the reason why nothing may be sent now; empty = clear to send
    [ -f "$D/disable" ] && { echo "own stop file present"; return; }
    [ -f "$OLD/disable" ] || { echo "old bridge is not paused (no $OLD/disable)"; return; }
    [ -n "$(pidof otto_navbridge)" ] && { echo "old bridge process is running"; return; }
    [ "$(getprop sys.ly.protocol)" = "rcp" ] || { echo "not in CarPlay mode (sys.ly.protocol=$(getprop sys.ly.protocol))"; return; }
    echo ""
}
# B9 / P8: "automatic time" being switched on does not mean the clock HAS been set (after a start the box showed an old date
# until network time arrived 34 s later). The clock counts as valid only when the time service reports that it set it.
clock_ok() {
    [ "$(settings get global auto_time 2>/dev/null)" = "1" ] || return 1
    cmd time_detector dump 2>/dev/null | grep -q -E 'mLastAutoSystemClockTimeSet=UnixEpochTime|NetworkTimeSuggestion\{'
}
hus_up() { ss -ltn 2>/dev/null | grep -q ':5277 '; }
prof() {                                  # prof RECEIVER KEY DEFAULT   ->  value from $D/profiles/<receiver>.conf, else DEFAULT
    v=$(sed -n "s/^$2=//p" "$D/profiles/$1.conf" 2>/dev/null | head -n 1)
    [ -n "$v" ] && echo "$v" || echo "$3"
}
st() { cut -d' ' -f22 /proc/$1/stat 2>/dev/null; }    # process start time (clock ticks after boot)
maps_kick() {                             # 0.7: a Maps that runs from before the Android Auto projection process never gives
    m=$(pidof $MAPS 2>/dev/null | cut -d" " -f1); p=$(pidof $PROJ 2>/dev/null | cut -d' ' -f1)   # its navigation to Android Auto (it is the
    [ -n "$m" ] && [ -n "$p" ] && [ "$(st $m)" -lt "$(st $p)" ] || return     # Home, so it starts at boot; car test 25-10-2026)
    if dumpsys activity services $MAPS 2>/dev/null | grep -A1 NavigationService | grep -q isForeground=true; then
        [ -z "$kwait" ] && log "Maps started before Android Auto but a route is running: restart postponed"; kwait=1; return
    fi
    front=$(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity)
    am force-stop $MAPS; log "Maps started before Android Auto: restarted so it gives its navigation to Android Auto"
    case "$front" in *" $MAPS/"*) sleep 1; input keyevent HOME;; esac     # Maps was in front: the OTTO Home brings it back
    kwait=
}
testopt() { [ -f "$D/test_options" ]; }   # 0.6: the TEST options are read only while this file exists
harden() {                                # 0.6: 5277 only from loopback (addendum 6); -C first so a rule is never added twice
    [ "$(cfg harden_5277 on on off)" = "on" ] || return 0
    for ipt in iptables ip6tables; do
        $ipt -w -C oem_in ! -i lo -p tcp --dport 5277 -j DROP 2>/dev/null && continue
        if $ipt -w -A oem_in ! -i lo -p tcp --dport 5277 -j DROP 2>/dev/null; then log "$ipt: port 5277 closed except loopback"
        else log "$ipt: could not add the 5277 rule"; fi
    done
}
GP=; GPSPID=$D/cargps.pid
gps_cleanup() { cmd location providers remove-test-provider gps >/dev/null 2>&1; }
stop_gps() {                              # the car GPS process gets the stop file (graceful: removes its test provider); the loop is just ended
    [ -n "$GP" ] || return 0
    touch "$GPSSTOP"; c=$(cat "$GPSPID" 2>/dev/null); n=0
    while [ -n "$c" ] && kill -0 "$c" 2>/dev/null && [ $n -lt 6 ]; do sleep 1; n=$((n+1)); done
    [ -n "$c" ] && kill -0 "$c" 2>/dev/null && { kill -KILL "$c" 2>/dev/null; log "car GPS did not stop in time: killed"; }
    kill -TERM "$GP" 2>/dev/null; wait "$GP" 2>/dev/null
    rm -f "$GPSPID"; gps_cleanup; GP=
}
gps_loop() {                              # runs in the background for the life of the supervisor
    glast=
    while :; do
        [ -f "$D/disable" ] && exit 0
        why=
        [ "$(cfg car_gps on on off)" = "on" ] || why="car_gps=off"
        [ -z "$why" ] && [ "$(getprop persist.ly.hugps.enable)" != "1" ] && why="persist.ly.hugps.enable is not 1"
        [ -z "$why" ] && [ ! -c "${OTTO_NAVI_CARGPS_DEV:-/dev/cargps_serial}" ] && why="no car GPS device"
        if [ -n "$why" ]; then [ "$why" != "$glast" ] && log "car GPS waiting: $why"; glast=$why; sleep "$WAIT"; continue; fi
        glast=; rm -f "$GPSSTOP"; gps_cleanup
        if [ -n "$OTTO_NAVI_CARGPS_CMD" ]; then $OTTO_NAVI_CARGPS_CMD --stop-file="$GPSSTOP" >> "$LOG" 2>&1 &
        else CLASSPATH="$BIN/otto_cargps.jar" app_process / OttoCarGps --identity=root --stop-file="$GPSSTOP" >> "$LOG" 2>&1 &
        fi
        c=$!; echo "$c" > "$GPSPID"; log "car GPS started pid=$c"
        wait "$c"; rc=$?; rm -f "$GPSPID"
        log "car GPS ended (code $rc)"; gps_cleanup
        [ -f "$GPSSTOP" ] && exit 0
        sleep "$RESTART"
    done
}
EP=; CP=
stop_pipe() {                             # engine first: it ends its own route (state 0) on SIGTERM
    [ -n "$EP" ] && kill -TERM "$EP" 2>/dev/null
    [ -n "$CP" ] && kill -TERM "$CP" 2>/dev/null
    [ -n "$EP" ] && wait "$EP" 2>/dev/null
    [ -n "$CP" ] && wait "$CP" 2>/dev/null
    EP=; CP=; rm -f "$FIFO"
}
trap 'log "stop signal"; stop_pipe; stop_gps; exit 0' TERM INT HUP

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
rot; log "start pid=$$ (0.7)"
harden
gps_loop & GP=$!
last=
while :; do
    if [ -f "$D/disable" ]; then log "own stop file present - exit"; stop_gps; exit 0; fi
    why=$(blocked)
    if [ -n "$why" ]; then [ "$why" != "$last" ] && log "waiting: $why"; last=$why; sleep "$WAIT"; continue; fi
    if ! hus_up; then
        am start-foreground-service -n "$HUS" >/dev/null 2>&1; sleep 5
        if ! hus_up; then [ "$last" != "hus" ] && log "waiting: Android Auto head unit server is not listening on 5277"; last=hus; sleep "$WAIT"; continue; fi
        log "Android Auto head unit server started"
    fi
    last=; harden
    RECV=$(cfg receiver none none mib4)
    SIDE=$(cfg side_default right right left none)
    # P8: the MIB4 can hold a definition from an earlier writer; the engine repeats the first one it sends instead of flushing
    CLEAN=$(prof "$RECV" startup_clean state0); CONF=
    CF=$(prof "$RECV" confirm_first ""); [ -z "$CF" ] && [ "$RECV" = "mib4" ] && CF=600       # 0.5 behaviour without a profile file
    [ -n "$CF" ] && [ "$CF" != "0" ] && CONF=--confirm-first=$CF
    RULES="--rbt-no-number=$(prof "$RECV" rbt_no_number auto) --left-off-ramp=$(prof "$RECV" left_off_ramp auto) --full-circle-ccw=$(cfg full_circle_ccw plus180 plus180 minus180)"
    DRY=; testopt && [ "$(cfg mode live live dry)" = "dry" ] && DRY=--dry
    LOGM=$(cfg log quiet quiet full)                                        # full: every message and event in the log (tests in the car)
    ETA=--eta=off; CLK=0; clock_ok && { ETA=--eta=clock; CLK=1; }       # arrival time only with a clock that has really been set
    RT=none; FEED=1000; RARGS=                                              # TEST ONLY: simulated drive from a position file
    testopt && { RT=$(cfg route none none A B); FEED=$(cfg feed_ms 1000 1000 500 286); }
    [ "$RT" != "none" ] && [ -f "$D/routes/$RT.txt" ] && RARGS="$D/routes/$RT.txt $FEED"
    rot; rm -f "$FIFO"; mkfifo "$FIFO" || { log "cannot create $FIFO"; sleep "$WAIT"; continue; }
    if [ -n "$OTTO_NAVI_ENGINE_CMD" ]; then $OTTO_NAVI_ENGINE_CMD $DRY --log=$LOGM --startup-clean=$CLEAN $CONF < "$FIFO" >> "$LOG" 2>&1 &
    else "$BIN/otto_rgid" run $DRY --log=$LOGM --startup-clean=$CLEAN $CONF < "$FIFO" >> "$LOG" 2>&1 &
    fi
    EP=$!
    MP=$(pidof $MAPS 2>/dev/null)
    if [ -n "$OTTO_NAVI_CLIENT_CMD" ]; then $OTTO_NAVI_CLIENT_CMD $RARGS --events-only --log=$LOGM --receiver=$RECV --side-default=$SIDE $RULES $ETA > "$FIFO" 2>> "$LOG" &
    else CLASSPATH="$BIN/otto_aanav.jar" app_process / OttoAaNav 127.0.0.1 0 $RARGS --events-only --log=$LOGM --receiver=$RECV --side-default=$SIDE $RULES $ETA > "$FIFO" 2>> "$LOG" &
    fi
    CP=$!
    log "pipe started client=$CP engine=$EP receiver=$RECV side=$SIDE clean=$CLEAN $CONF $RULES $ETA $DRY maps=[$MP] route=[$RARGS]"
    quick=; rc=
    maps_kick
    while kill -0 "$EP" 2>/dev/null && kill -0 "$CP" 2>/dev/null; do
        sleep "$POLL"
        why=$(blocked)
        if [ -n "$why" ]; then log "stopping the pipe: $why"; break; fi
        maps_kick
        m=$(pidof $MAPS 2>/dev/null)
        if [ "$CLK" = "0" ] && clock_ok; then log "the clock has been set now: new session with arrival time"; quick=1; break; fi
        if [ -n "$m" ] && [ "$m" != "$MP" ]; then log "Maps process appeared after the session began (was [$MP], now [$m]): new session"; quick=1; break; fi
    done
    kill -0 "$EP" 2>/dev/null || log "engine ended"
    if ! kill -0 "$CP" 2>/dev/null; then wait "$CP" 2>/dev/null; rc=$?; log "client ended (code $rc)"; fi
    stop_pipe
    if [ "$rc" = "11" ]; then log "head unit server accepts but does not answer: stopping it (it is started again in the next round)"; am stopservice -n "$HUS" >/dev/null 2>&1; sleep 2
        # seen on the device: after the stop command the old process can keep a dead listener on 5277; only a new process is clean
        for p in $(pidof $PROJ 2>/dev/null); do kill "$p" 2>/dev/null && log "ended Android Auto projection process $p"; done; sleep 3; fi
    [ -f "$D/disable" ] || [ -n "$quick" ] || sleep "$RESTART"
done
