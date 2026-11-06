# Car GPS into Android — and why Maps says "Searching for GPS"

**The finding that will save you days:** Google Maps *navigation* drops a location stream that has no satellite count,
even when the fixes are fresh, moving and accurate. It showed "Searching for GPS" 30–60 s after the start of every drive.
Adding the Location extra **`satellites`** to every fix fixed it (proven on drives, 2026-11-01 and 2026-11-06).

## The bridge (`../../src/navi/cargps/OttoCarGps.java`)
- The car's position arrives as NMEA in `/dev/cargps_serial` (the OEM kernel module; the OEM `lylinkservice` writes it when
  `persist.ly.hugps.enable=1`). Your source may be a serial port, Bluetooth GPS or a socket — the Android side is the same.
- One long-lived process (`app_process`, root) registers a **test provider named `gps`** through `ILocationManager`
  (`addTestProvider`, `setTestProviderEnabled`, `setTestProviderLocation`, `removeTestProvider`). Android only checks the
  app-op MOCK_LOCATION for the package you name.
- While the car is silent, the test provider is removed again, so the device's own GNSS is `gps` as before.
- Fill in what you know: accuracy, speed, bearing, and their accuracies.

## The fix in a few lines
```java
Bundle extras = new Bundle();
extras.putInt("satellites", 12);   // the car sends no count; 12 stands for "good fix"
location.setExtras(extras);
locationManager.setTestProviderLocation("gps", location);
```
In our bridge: `--sat-extra=12` (default), `--sat-extra=0` turns it off.

## Other things we learned
- **1 fix/s looks jumpy** on the map arrow. The bridge predicts positions at 10 Hz from speed, course, turn rate and
  acceleration, never more than 1.5 s ahead, and a real fix always replaces the estimate. (This was *not* the cause of
  "Searching for GPS": we tested without prediction, it still failed.)
- **No network time in the car?** The bridge sets the system clock from the GPS UTC when it is more than 1 h off,
  and judges freshness by arrival time while the clock is unset.
- `dumpsys location` shows the last `gps` location with its extras: look for `satellites=12` to see the fix is in.
- Test parked first: feed recorded NMEA into the bridge while Maps navigates (`../../tests/gps-parked/`). But only a drive
  proves it: a parked test once "disproved" the satellite fix; the drive showed the real effect.
