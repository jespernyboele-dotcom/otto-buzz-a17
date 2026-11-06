# OTTO guides — what we learned, written for others

These guides come from the OTTO project: an Ottocast P3 Pro (Qualcomm SM6225, eMMC) moved from its stock Android 13 to
an Android 17 GSI, with the OEM CarPlay chain kept, in a VW ID. Buzz (MIB4, 1920×840). Each folder stands on its own:
read only the one you need.

| # | Guide | Useful if you… |
|---|---|---|
| 01 | [Root with Magisk over EDL](01-root-with-magisk-over-edl/) | want root on a Qualcomm box without fastboot, with a byte-exact rollback |
| 02 | [EDL backup and rescue](02-edl-backup-and-rescue/) | want a lifeline that works even when Android does not boot |
| 03 | [Android 17 GSI, keeping the OEM CarPlay](03-android17-gsi-keeping-oem-carplay/) | want a new Android on a car box without losing what makes it a car box |
| 04 | [CarPlay projection at 60 fps](04-carplay-projection-60fps/) | stream an Android screen to a car as H.264 and want it smooth and sharp |
| 05 | [Car GPS into Android, and Maps "Searching for GPS"](05-car-gps-into-android-maps/) | feed an external GPS (car, NMEA, mock) to Android and Maps navigation loses it |
| 06 | [Measure real fps with a phone camera](06-measure-real-fps-with-a-phone-camera/) | want to know how many pictures the car screen *really* shows |
| 07 | [Maps safe zone with a display cutout](07-maps-safe-zone-display-cutout/) | want apps to keep a strip of the screen free for your own panel |
| 08 | [Safe live changes — lessons learned](08-safe-live-changes-lessons-learned/) | change a running device you depend on (a car!) and want to keep it working |
| 09 | [Maps turn-by-turn to the car's cluster](09-android-auto-navigation-to-car-cluster/) | want the car's instrument cluster to show the arrows from Google Maps |

**Read this first**
- These are real procedures from one device. Partition numbers, LBAs and hashes are **ours**: read your own, never copy them.
- Anything that writes to a partition can brick your device. Every guide says which steps are read-only.
- Not included, ever: firmware images, the Firehose programmer, OEM binaries, Google apps, keys. You need your own.
  One exception: `src/navi/engine/OttoAaNav.java` (guide 09) contains the Android Auto head-unit certificate and key that
  the open-source head unit projects already publish. It is public, not ours, and protects nothing.
- "Proven" below means measured on the device or in the car. Things we did not test are marked **NOT TESTED**.
