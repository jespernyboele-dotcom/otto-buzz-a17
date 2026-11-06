#!/system/bin/sh
# OTTO: reproduce init's on-device SELinux compile (AOSP selinux.cpp argument order), read-only test.
T=/data/local/tmp/otto_se; V=$(cat /vendor/etc/selinux/plat_sepolicy_vers.txt)
run(){ label=$1; plat=$2; shift 2
  set -- /system/bin/secilc "$plat" -m -M true -G "$@" -c 30 /system/etc/selinux/mapping/$V.cil \
     /system/etc/selinux/mapping/$V.compat.cil \
     /system/system_ext/etc/selinux/system_ext_sepolicy.cil /system/system_ext/etc/selinux/mapping/$V.cil \
     /system/system_ext/etc/selinux/mapping/$V.compat.cil \
     /system/product/etc/selinux/product_sepolicy.cil /system/product/etc/selinux/mapping/$V.cil \
     /vendor/etc/selinux/plat_pub_versioned.cil /vendor/etc/selinux/vendor_sepolicy.cil \
     -o $T/policy.$label -f /dev/null
  "$@" > $T/secilc.$label.log 2>&1; rc=$?
  echo "$label rc=$rc size=$(stat -c %s $T/policy.$label 2>/dev/null) $(tail -2 $T/secilc.$label.log | tr '\n' ' ')"
}
run vanilla_N  /system/etc/selinux/plat_sepolicy.cil -N
run k1_N       $T/plat_sepolicy.k1.cil -N
run vanilla_NA /system/etc/selinux/plat_sepolicy.cil
run k1_NA      $T/plat_sepolicy.k1.cil
sha256sum $T/policy.* 2>/dev/null
