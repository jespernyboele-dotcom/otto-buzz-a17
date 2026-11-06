# Parked car-GPS test

Feeds a fake drive (RMC + GGA at 1 Hz, current UTC, 12 m/s north-east, no satellite count — like the car) through a
FIFO into an `OttoCarGps` jar on OTTO while Maps navigates, takes a screenshot and cleans up (stops the test
instance, removes the `gps` test provider).

```
adb -s <OTTO_IP>:29527 push otto_cargps.jar /data/local/tmp/p5.jar
OTTO_ADB=<OTTO_IP>:29527 START_LAT=<lat> START_LON=<lon> OUT=/some/dir ./run_feed.sh p5 60
```

Preconditions: a Maps route running on OTTO; the car silent on car GPS (parked, car off) so the supervisor's own
`otto_cargps` stays in state OTTO. 2026-10-26 result with the unchanged P5 bridge: Maps followed at 39 km/h,
no "Searching for GPS".

> **Note (2026-11-06):** this parked test passed *without* satellite extras, which made us reject them (P6) on 26.10.
> The drive on 2026-11-01 proved the opposite: Maps navigation needs them while driving
> (`../../evidence/2026-11-01-gps-searching/`). A parked pass is not a driving pass.
