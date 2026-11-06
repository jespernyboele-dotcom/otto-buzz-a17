#!/data/data/com.termux/files/usr/bin/bash
# OTTO A17 permanent — apply the four image changes to an EXTRACTED ext4 system image (offline, phone).
#   1 /system/etc/selinux/plat_sepolicy.cil  += otto_k1_art_vector.cil   (ART/Vector K1)
#   2 /system/bin/ottoctl                     -> fixed (absolute su)        (FINAL-R1 fix 1b)
#   3 /system/bin/su -> /debug_ramdisk/su      new symlink                  (FINAL-R1 fix 1a)
#   4 /system/bin/otto_firstboot.sh           += fixes 2-4                  (FINAL-R1 fixes 2-4)
# Each replaced file keeps the original mode, uid, gid and security.selinux xattr (copied byte-exact).
# Usage: patch_system_image.sh <image.raw> <system_files_dir> <logfile>
set -Eeuo pipefail
IMG=$1; SF=$2; LOG=$3
T=$(mktemp -d); trap 'rm -rf $T' EXIT
exec > >(tee -a "$LOG") 2>&1
echo "== patch_system_image $(date '+%F %T') img=$IMG"
dfs(){ debugfs -w -R "$1" "$IMG" 2>&1 | grep -v '^debugfs ' || true; }
dro(){ debugfs -R "$1" "$IMG" 2>/dev/null; }
replace(){ # <path in image> <new local file>
  local p=$1 f=$2
  local st; st=$(dro "stat $p") || true
  [ -n "$st" ] || { echo "MISSING $p"; exit 3; }
  local mode uid gid
  mode=$(echo "$st" | sed -n 's/.*Mode: *\(0[0-7]*\).*/\1/p' | head -1)
  uid=$(echo "$st" | sed -n 's/.*User: *\([0-9]*\).*/\1/p' | head -1)
  gid=$(echo "$st" | sed -n 's/.*Group: *\([0-9]*\).*/\1/p' | head -1)
  debugfs -R "ea_get -f $T/ctx $p security.selinux" "$IMG" >/dev/null 2>&1
  [ -s $T/ctx ] || { echo "NO_SELINUX_XATTR $p"; exit 4; }
  dro "cat $p" > $T/orig.bin
  echo "replace $p mode=$mode uid=$uid gid=$gid ctx=$(tr -d '\0' < $T/ctx) old_sha=$(sha256sum < $T/orig.bin | cut -c1-16) new_sha=$(sha256sum < $f | cut -c1-16)"
  dfs "rm $p"
  dfs "write $f $p"
  dfs "set_inode_field $p mode 0100${mode#0}"
  dfs "set_inode_field $p uid $uid"
  dfs "set_inode_field $p gid $gid"
  dfs "ea_set -f $T/ctx $p security.selinux"
  dro "cat $p" | cmp - "$f" && echo "  verify content OK"
}
replace /system/etc/selinux/plat_sepolicy.cil "$SF/patched/plat_sepolicy.cil"
replace /system/bin/ottoctl                 "$SF/patched/ottoctl"
replace /system/bin/otto_firstboot.sh       "$SF/patched/otto_firstboot.sh"
# su symlink (root:shell 0777 lnk, system_file)
if dro "stat /system/bin/su" | grep -q Inode; then echo "su already present"; else
  printf 'u:object_r:system_file:s0\0' > $T/sysctx
  dfs "symlink /system/bin/su /debug_ramdisk/su"
  dfs "set_inode_field /system/bin/su uid 0"
  dfs "set_inode_field /system/bin/su gid 2000"
  dfs "ea_set -f $T/sysctx /system/bin/su security.selinux"
  echo "symlink /system/bin/su -> $(dro 'stat /system/bin/su' | sed -n 's/.*Fast link dest: "\(.*\)"/\1/p')"
fi
echo "== e2fsck -fn"
e2fsck -fn "$IMG" && echo "E2FSCK_CLEAN"
