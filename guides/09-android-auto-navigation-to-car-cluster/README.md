# Turn-by-turn from Google Maps to the car's instrument cluster (Android Auto → iAP2 Route Guidance)

**Result on OTTO:** while Google Maps navigates on the box, the VW ID. Buzz shows the manoeuvres (arrow, distance,
street) in its instrument cluster, as it does for a phone with CarPlay. Accepted in the car 2026-10-26 (display). Our receiver is the MIB4; other CarPlay head units should work the same way, but we only tested this one.

## The idea
The car only understands CarPlay's **iAP2 Route Guidance** messages. Maps doesn't speak them, but Maps *does* send
turn-by-turn to **Android Auto**, and Android Auto has a built-in head unit server for developers (TCP on `127.0.0.1:5277`).
So we pretend to be an Android Auto car on the box itself, take the navigation messages, and translate them:
```
Google Maps ─► Android Auto ─► 127.0.0.1:5277 ─► OttoAaNav (fake head unit) ─► OttoAaConv ─event lines─► otto_rgid ─► OEM iAP2 socket ─► car
```
No video is streamed through Android Auto; the picture still goes over CarPlay (guide 04).

## The parts (`../../src/navi/`)
| Part | What it does |
|---|---|
| `engine/OttoAaNav.java` | Minimal headless Android Auto head unit client: TLS to `127.0.0.1:5277`, announces protocol 1.7 and the smallest service set Android Auto accepts (sensor, video, input, audio, mic, **navigation status**), keeps video focus native (nothing streamed), grants navigation focus, and passes every navigation-channel message on. It uses the public head-unit certificate from the open-source head unit projects. |
| `engine/OttoAaConv.java` | Strict protobuf reader for the navigation messages (`0x8003`, `0x8006`, `0x8007`) → a normalized model → engine event lines (`MAN`, `LANE`, `TRIP`, `COMMIT`, …). Values never observed get no invented meaning: they are carried as UNKNOWN with the raw number. |
| `engine/otto_rgid.c` | Route-guidance engine: keeps the iAP2 caches (`0x5202` manoeuvres, `0x5204` lanes, `0x5201` route snapshot), adopts a new route atomically on `COMMIT`, debounces reroutes (3 s), answers the car's start/stop (`0x5200`/`0x5203`), and sends over the OEM's abstract Unix socket (`@com.liaoyuan.rlink.iapserver2` on Ottocast boxes). Messages stay below 2048 bytes (the OEM buffer). |
| `otto_navi.sh` | Supervisor: one pipe client → engine, restarts it, also runs the car-GPS bridge (guide 05). |

## What made it work
- **Start the head unit server yourself:** `am start-foreground-service -n com.google.android.projection.gearhead/.companion.DeveloperHeadUnitNetworkService`.
  It belongs to Android Auto's developer settings. If it won't start, turn on Android Auto developer mode once.
- **Android Auto binds the navigation app only when a session is created.** If Maps starts after the session, that
  session never gets navigation data → restart the pipe when the Maps process appears or changes.
- **A server that accepts but never answers** happens: stop the service and start it again in the next round.
- **Close 5277 to everything but loopback** (two firewall rules): the developer server must not be reachable from Wi-Fi.
- **One sender on the car socket, never two.** Only send when the box is in CarPlay mode, any older bridge is stopped,
  and your own stop file is absent. Check this before every start and every 15 s.
- **Per-car quirks in a profile file**, not in code (`profiles/<receiver>.conf`, keys such as `confirm_first`, `startup_clean`,
  `rbt_no_number`, `left_off_ramp`), so a second car type doesn't need a rebuild.
- **On stop, end the route** (state 0) so the cluster doesn't keep showing an old arrow.

## Test without driving
- `otto_rgid fixture` reads event lines and prints what it *would* send (`TX …`). Build your test cases as text files.
- `OttoAaNav replay <capture>` runs recorded navigation messages through the same code path, with no network.
- A test option feeds positions from a recorded route to Android Auto, so Maps follows a route while the car is parked.
  Test options are only read while a `test_options` file exists, so they can't stay on by mistake.

## Known limit
The cluster only moves when Maps has a GPS fix. If Maps shows "Searching for GPS", the route data freezes. On OTTO that
was the cause of the frozen cluster we saw on 2026-10-26; guide 05 fixes it.
