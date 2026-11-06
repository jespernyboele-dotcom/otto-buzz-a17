# Keep a strip of the screen free for your own panel (display cutout overlay)

OTTO shows Google Maps across the whole car screen, with its own panel on the right. To stop Maps from putting its buttons
under that panel, we tell Android that the right 576 px are a **display cutout** (like a camera notch). Apps lay out their
controls outside it; Maps still draws the map edge to edge underneath.

## The overlay (`example-overlay/`)
A resource overlay (RRO) for the `android` package:
```xml
<string name="config_mainBuiltInDisplayCutout">@bind_right_cutout M 0,1 L -576,1 L -576,839 L 0,839 Z @right</string>
<string name="config_mainBuiltInDisplayCutoutRectApproximation">…same…</string>
<bool name="config_fillMainBuiltInDisplayCutout">false</bool>
<bool name="config_maskMainBuiltInDisplayCutout">false</bool>
```
- The path is in screen pixels; `@right` with negative x counts from the right edge. Set your own width and height.
- `category="com.android.internal.display_cutout_emulation"` and **not static** in the manifest: the same mechanism as the
  "Simulate a display with a cutout" developer option, so you can switch it at runtime.

## Build, install, switch
1. `ANDROID_JAR=… KEYSTORE=… sh build_overlay.sh` → `SafeZoneOverlay.apk`.
2. Put it in `/system/product/overlay/` (on OTTO it is part of the system image) and reboot once so the overlay is known.
3. As root: `cmd overlay enable dk.otto.overlay.safezone` / `cmd overlay disable …`. Our launcher turns it on for Home
   and off for full-screen apps.

## Make switching fast
- Turn the zone on **before** the app comes to the front, not after: otherwise the app first lays out in full width,
  then again (on the car: a black flash and ~3.6 s until Home looked right; after the change ~0.7 s).
- Keep **one persistent root shell** open instead of starting `su` for every switch, and skip the call when the zone is
  already in the wanted state.

## What failed
A cutout with **two segments** (a strip on the left *and* the right) turned the car screen black. We rolled it back.
Test one change per boot, so you know which one did it.
