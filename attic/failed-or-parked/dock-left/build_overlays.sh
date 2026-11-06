#!/bin/sh
# Builds the two OTTO cutout overlays (aapt2 compile/link, zipalign, apksigner with the same debug key as the existing ones).
set -e
cd "$(dirname "$0")"
AJ=/data/data/com.termux/files/home/android-sdk/platforms/android-36/android.jar
KS=/data/data/com.termux/files/home/.android/debug.keystore
for n in dockleft:OttoDockLeft safezone_v2:OttoSafeZone; do
  d=${n%%:*}; a=${n##*:}; W=$(mktemp -d)
  aapt2 compile --dir $d/res -o $W/res.zip
  aapt2 link -o $W/u.apk -I $AJ --manifest $d/AndroidManifest.xml $W/res.zip
  zipalign -f 4 $W/u.apk $W/a.apk
  apksigner sign --ks $KS --ks-pass pass:android --key-pass pass:android --out out/$a.apk $W/a.apk
  rm -rf $W; sha256sum out/$a.apk
done
