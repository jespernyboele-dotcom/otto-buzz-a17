#!/system/bin/sh
# OTTO final-build pre-test 2 (2026-11-01). Magisk post-fs-data.d: bind-mounts the candidates for the last A17 build
# over the image paths for this boot only; nothing on /system is written. Each file is sha-guarded and relabelled
# system_file (as in the image). F3/F4/F14 boot scripts, F6/F7 otto_cargps, F11 ly_link.sh supervisor, F10/F10b
# patched lylinkservice/lyscrservice. Undo: rm /data/adb/post-fs-data.d/91-otto-final-test.sh and reboot.
D=/data/adb/otto/final_test; L=/data/adb/otto/logs/final_test.log; out=""
while read f s t; do
  if [ -f "$D/$f" ] && [ "$(sha256sum $D/$f | cut -d' ' -f1)" = "$s" ]; then
    chcon u:object_r:system_file:s0 $D/$f; mount -o bind $D/$f $t && out="$out $f=bound" || out="$out $f=mount-failed"
  else out="$out $f=skipped"; fi
done <<'TABLE'
otto_cargps.jar 7cff74454cff6f2552f949e11567c387d86ffc5c68e5697f9717440b0442ac7c /system/etc/otto/navi/bin/otto_cargps.jar
run.sh 5e105e9ae282a5f37a52964e4862cd957988c2e087c885d98da68380b0dc21e7 /system/etc/otto/boot/run.sh
25-otto-hwc-vds-confirm.sh 0dbd04128b26904322be6aec2574c2361c1128d0e1f78a2611b99c3c7d2e16c0 /system/etc/otto/boot/service.d/25-otto-hwc-vds-confirm.sh
24-otto-a3a-gpu465.sh df1a1c3f5fadc63753a6428630f87f850aaf70bfc2d432e45bd1cb90612e2d68 /system/etc/otto/boot/service.d/24-otto-a3a-gpu465.sh
ly_link.sh 6198d676a94d35bff39043e285b097830863fb2fb8231a75497b1fdee982f86a /system/bin/ly_link.sh
lylinkservice 9b3b76b5f5cf924087411a1ebd17220334770cfc8792eb0dbe4974bdfa7d27dd /system/bin/lylinkservice
lyscrservice 8c727747e14571698c4a4082e16224255fc1af6787815f3c602863db35488a75 /system/bin/lyscrservice
TABLE
mkdir -p /data/adb/otto/logs; echo "$(date '+%F %T') boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)$out" >> $L
