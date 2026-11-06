# Spotify warm-up after boot — tested, NOT installed

After boot Spotify has no media session: the Home card shows the last song without cover, and Play opens the app
(launcher v10 falls back to `openApp` when MEDIA_PLAY gets no playback within 3 s).

`95-otto-spotify-warm.sh` (Magisk `service.d`) waits for boot and for Home/Maps in front, opens OTTO Spotify
(`dk.otto.spotify`) until Spotify's session has a song (it binds Spotify's `AutomotiveMediaBrowserService`, which
restores the last song PAUSED with cover), then returns to Home. It skips when Spotify already has a song or when
Home/Maps is not in front. Log: `/data/adb/otto/logs/spotify_warm.log`.

Hand test 2026-10-26 (Spotify force-stopped): song + cover ready after 2 s, Maps back in front.
Install (not done): copy to `/data/adb/service.d/`, `chmod 755`. Remove: delete the file.
