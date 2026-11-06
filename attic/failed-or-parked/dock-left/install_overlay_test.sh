#!/system/bin/sh
# Run once on OTTO as root: builds /data/adb/otto/overlay_test from the live overlay dir + the two new APKs (pushed to
# /data/local/tmp), installs hook 92. Takes effect at the next boot.
set -e
D=/data/adb/otto/overlay_test
rm -rf $D.new; mkdir -p $D.new
cp -a /system/product/overlay/. $D.new/
cp /data/local/tmp/OttoDockLeft.apk $D.new/OttoDockLeft.apk
cp /data/local/tmp/OttoSafeZone.apk $D.new/OttoSafeZone.apk
chmod 644 $D.new/OttoDockLeft.apk $D.new/OttoSafeZone.apk
sync; rm -rf $D; mv $D.new $D
cp /data/local/tmp/92-otto-overlay-test.sh /data/adb/post-fs-data.d/92-otto-overlay-test.sh.new
chmod 755 /data/adb/post-fs-data.d/92-otto-overlay-test.sh.new; sync
mv /data/adb/post-fs-data.d/92-otto-overlay-test.sh.new /data/adb/post-fs-data.d/92-otto-overlay-test.sh; sync
ls -la $D | head -30; sha256sum $D/OttoDockLeft.apk $D/OttoSafeZone.apk
