#!/system/bin/sh
# PORT 2: init's on-device SELinux compile (AOSP selinux.cpp argument order) with the OTTO additions.
T=/data/local/tmp/otto_se; mkdir -p $T; V=$(cat /vendor/etc/selinux/plat_sepolicy_vers.txt)
cat /system/etc/selinux/plat_sepolicy.cil /data/local/tmp/otto_plat.cil > $T/plat.otto.cil
cat /vendor/etc/selinux/vendor_sepolicy.cil /data/local/tmp/otto_vendor.cil > $T/vendor.otto.cil
run(){ label=$1; plat=$2; vend=$3; shift 3
  /system/bin/secilc "$plat" -m -M true -G "$@" -c 30 /system/etc/selinux/mapping/$V.cil \
     /system/etc/selinux/mapping/$V.compat.cil \
     /system/system_ext/etc/selinux/system_ext_sepolicy.cil /system/system_ext/etc/selinux/mapping/$V.cil \
     /system/system_ext/etc/selinux/mapping/$V.compat.cil \
     /system/product/etc/selinux/product_sepolicy.cil /system/product/etc/selinux/mapping/$V.cil \
     /vendor/etc/selinux/plat_pub_versioned.cil "$vend" -o $T/policy.$label -f /dev/null > $T/secilc.$label.log 2>&1
  echo "$label rc=$? size=$(stat -c %s $T/policy.$label 2>/dev/null) $(tail -1 $T/secilc.$label.log)"; }
run vanilla_N /system/etc/selinux/plat_sepolicy.cil /vendor/etc/selinux/vendor_sepolicy.cil -N
run otto_N $T/plat.otto.cil $T/vendor.otto.cil -N
