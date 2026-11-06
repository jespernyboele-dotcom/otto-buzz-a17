#!/bin/sh
# Builds example-overlay/ into SafeZoneOverlay.apk: aapt2 compile/link, zipalign, apksigner.
# Usage: ANDROID_JAR=<sdk>/platforms/android-36/android.jar KEYSTORE=<your.keystore> sh build_overlay.sh
# (Termux: pkg install aapt2 apksigner zipalign; any debug keystore works for a runtime overlay.)
set -e
cd "$(dirname "$0")"
: "${ANDROID_JAR:?set ANDROID_JAR}"; : "${KEYSTORE:?set KEYSTORE}"; KS_PASS=${KS_PASS:-android}
W=$(mktemp -d)
aapt2 compile --dir example-overlay/res -o $W/res.zip
aapt2 link -o $W/u.apk -I "$ANDROID_JAR" --manifest example-overlay/AndroidManifest.xml $W/res.zip
zipalign -f 4 $W/u.apk $W/a.apk
apksigner sign --ks "$KEYSTORE" --ks-pass pass:$KS_PASS --key-pass pass:$KS_PASS --out SafeZoneOverlay.apk $W/a.apk
rm -rf $W; sha256sum SafeZoneOverlay.apk
