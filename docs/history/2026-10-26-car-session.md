# Car session 2026-10-26 — FINAL2 acceptance, bitrate, GPS

OTTO: FINAL2 on slot `_b` + Recorder R3 (8 Mbit/s) from `/data`. Car: VW ID. Buzz (MIB4), wireless CarPlay.
Read over Wi-Fi adb (home Wi-Fi and the car hotspot). Nothing flashed this day.

## Acceptance (owner in the car)
| Item | Result |
|---|---|
| CarPlay picture + audio | PASS |
| Steering-wheel keys incl. voice key | PASS (voice key: leave as is) |
| Car GPS into Android | PASS — `otto_cargps` state=CAR, 1 Hz, stale=0, gaps ≈1000 ms, hAcc 5 m, speed/bearing correct |
| NAVI on the instrument cluster | PASS (display) — but see "Maps Searching for GPS" |
| Projection smear when panning Maps | first looked fixed by 8 Mbit/s; **returned later that day** (owner, 2026-10-31) |
| 30-min drive + `car_measure.sh` | not done |

## Projection bitrate (R3)
- R3 = R2 + bitrate from `/data/adb/otto/config/recorder_bitrate` for standby server **and** every session
  (FINAL2 forced 4 194 304 for the first session after boot) + 10 s stats in `/data/adb/otto/logs/recorder.log`.
- 8 Mbit/s in the car: no smear when panning/zooming Maps, video plays. Encoder bursts 13–16 Mbit/s on motion,
  0–1 Mbit/s when static.
- **Decision:** keep 8 Mbit/s permanently as the `/data` bind-mount (survives reboots, lost only on a userdata wipe).
  No FINAL3. Source and scripts: `attic/superseded/recorder/recorder3/`. Loaded lib sha256 `6b38d2df…2903c0`.
- Caveat (also in FINAL2): HWC-VDS is confirmed ≈200 s after boot; a power-off before that disables VDS next boot.

## Findings
- **Pinch-zoom is impossible in CarPlay on this car.** The HU's HID descriptor (`/tmp/lyHidDes.bin`, bplist
  `hidDevices`) declares a touch screen with exactly one finger; `getevent` on "LY Touchscreen" during pinch shows only
  slot 0. Android Auto uses another protocol, which is why pinch works there. Workaround: double tap / tap-hold-drag.
- **Boot animation is never visible in the car.** It plays on OTTO's display 0, but the projection mirrors only the
  window hierarchy, and projection starts ≈60 s after boot anyway.
- **Home Spotify play opens the app after boot.** After boot Spotify has no media session, so the Home card shows the
  last song without cover; `OttoMapsWidgetOverlay.resume()` sends MEDIA_PLAY and falls back to `openApp` after 3 s.
  Binding Spotify's `AutomotiveMediaBrowserService` (opening OTTO Spotify once) restores the last song PAUSED with
  cover. A boot script that does this is in `attic/failed-or-parked/spotify-warm/` — tested by hand (2 s), **not installed**.

## Open: Maps navigation shows "Searching for GPS" while driving
Symptom: speed "-- km/h", route frozen (navi.log `dest_m` never counts down), position jumps only now and then,
although car fixes arrive every second and Maps receives them (≈2 locations/s on `gps`, `fused` equal and fresh).

Ruled out:
- Location time (cargps uses RMC UTC; ±5 s stale check passes; DST change irrelevant).
- Location settings / permissions (location on, high accuracy; Maps and Play services have fine + background).
- Build changes: GPS chain identical to the pre-24.10 module (navi 0.7 only adds `maps_kick`); MapsMod hooked UI only.
- Maps started before car GPS: restarting Maps mid-drive helped for a minute, then "Searching" returned.
- Missing satellite extras: a P6 bridge adding `satellites/meanCn0/maxCn0` was built, but a parked control test
  with the **unchanged** P5 bridge already navigated fine (39 km/h, no "Searching"). P6 not deployed.

Best hypothesis: Maps' "Searching for GPS" follows OTTO's **own** GNSS status, not the injected positions. Parked at
home OTTO's own GNSS has a strong fix (9–12 sats, C/N0 34/46) → fine; in the car while driving it was weak
(avg C/N0 25.6) → "Searching". Next steps if resumed: antenna placement / reception of OTTO's own GNSS, or keep
OTTO's GNSS from reporting a no-fix status while car GPS is active. Car GPS stays primary (owner decision).
Parked test harness: `tests/gps-parked/`.

## End state
Owner stopped optimizing on 2026-10-26 ("goal reached: A17 on OTTO"). Nothing half-applied on the device.
