#!/system/bin/sh
# OTTO Spotify warm-up (2026-10-26). Magisk service.d, no build, no flash.
# After boot Spotify has no media session, so Home shows the last song without cover and
# Play falls back to opening the app. Opening OTTO Spotify once binds Spotify's
# AutomotiveMediaBrowserService; Spotify then restores the last song PAUSED with cover.
# This opens OTTO Spotify for a few seconds while Home/Maps is in front, then returns to Home.
# Undo: rm /data/adb/service.d/95-otto-spotify-warm.sh
LOG=/data/adb/otto/logs/spotify_warm.log
log() { echo "$(date '+%F %T') $*" >> $LOG; }
top() { dumpsys activity activities 2>/dev/null | grep topResumedActivity | sed -n 1p; }
# Home = OTTO Home or Maps (Home brings Maps to front with the panel beside it)
at_home() { top | grep -qE 'OttoHomeActivity|com.google.android.apps.maps/'; }
spotify_ready() { dumpsys media_session | sed -n '/package=com.spotify.music/,/package=/p' | grep -q 'metadata: size=[1-9]'; }

(
  i=0; until [ "$(getprop sys.boot_completed)" = 1 ] || [ $i -ge 180 ]; do sleep 1; i=$((i+1)); done
  i=0; until at_home || [ $i -ge 90 ]; do sleep 1; i=$((i+1)); done
  sleep 5
  if spotify_ready; then log "skip: Spotify session already has a song"; exit 0; fi
  if ! at_home; then log "skip: Home not in front ($(top))"; exit 0; fi
  am start -n dk.otto.spotify/.SpotifyActivity >/dev/null 2>&1
  i=0; until spotify_ready || [ $i -ge 15 ]; do sleep 1; i=$((i+1)); done
  sleep 1
  top | grep -q dk.otto.spotify && am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
  spotify_ready && log "ok: Spotify warmed after ${i}s" || log "fail: no Spotify song after ${i}s"
) </dev/null >/dev/null 2>&1 &
