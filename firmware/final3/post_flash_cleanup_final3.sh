#!/system/bin/sh
# OTTO A17 FINAL3 — post-flash cleanup (runs ON OTTO as root, once, after the first FINAL3 boot).
# FINAL3 carries everything in /system. This removes the /data test scaffolding of 2026-10-31/11-01 so nothing
# is bind-mounted over the image any more. Literal paths only. Kept: /data/adb/otto/config/recorder_bitrate,
# logs, the owner's apps and settings. Reboot afterwards, then run postboot_verify_device.sh.
# Usage: adb -s <otto>:29527 shell su -c sh /data/local/tmp/post_flash_cleanup_final3.sh
L=/data/adb/otto/logs/post_flash_final3.log
say() { echo "$(date '+%F %T') $*" | tee -a $L; }
say "start boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id) slot=$(getprop ro.boot.slot_suffix)"

# The image must be FINAL3 before anything is removed (the hooks are only redundant once /system has the files).
[ "$(sha256sum /system/bin/lylinkservice | cut -c1-16)" = 9b3b76b5f5cf9240 ] || { say "ABORT: /system is not FINAL3"; exit 1; }
grep -q " /system/bin/lylinkservice " /proc/mounts && say "note: lylinkservice still bind-mounted (hook 91 this boot)"

for f in /data/adb/post-fs-data.d/90-otto-rec-test.sh /data/adb/post-fs-data.d/91-otto-final-test.sh \
         /data/adb/otto/config/stream_dump /data/adb/otto/smear_sampler.sh /data/adb/otto/smear_sampler.stop; do
  [ -e $f ] && rm -f $f && say "removed $f"
done
for d in /data/adb/otto/rec_test /data/adb/otto/final_test; do
  [ -d $d ] && rm -rf $d && say "removed $d/"
done
sync

# The launcher and OTTO Spotify are now system apps from the image: compile them once (the screen never turns
# off, so Android's idle dexopt never runs; F16).
for p in io.github.seijikohara.femto.otto dk.otto.spotify; do
  say "compile $p: $(cmd package compile -m speed -f $p 2>&1 | tail -1)"
done
say "left in post-fs-data.d: [$(ls /data/adb/post-fs-data.d 2>/dev/null | tr '\n' ' ')] service.d: [$(ls /data/adb/service.d 2>/dev/null | tr '\n' ' ')]"
say "bitrate=$(cat /data/adb/otto/config/recorder_bitrate 2>/dev/null)"
say "DONE: sync, then reboot (adb reboot) and run postboot_verify_device.sh"
sync
