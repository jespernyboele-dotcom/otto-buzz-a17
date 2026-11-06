#!/system/bin/sh

echo "86364000" > /proc/sys/net/core/rmem_max

function ly_fun_rcp_init() {
	echo "ly rcp"
	setprop sys.usb.configfs 2
	mdnsd &
	nice -n -20 /system/bin/lyscrservice &
	nice -n -20 lylinkservice -p=LY6225 &
}

function ly_fun_raa_init() {
	echo "ly raa"

	mdnsd &
	nice -n -20 /system/bin/lyscrservice &
	nice -n -20 lylinkservice -p=LY6225 &
}

# 强制正向carplay界面返回android系统的icon使用指定icon，未设置时使用默认icon
setprop persist.ly.force.oemicon 1

# OTTO: ADB mode = wired (usb) or wireless. The factory menu (LYFactoryTools) stores its choice in
# persist.ctz.adb.config (usb = wired). The latest change wins:
#  - the physical AA/CP switch (only moved while the box is off): if it moved since the last boot,
#    AA sets wired and CP sets wireless (clears persist.ctz.adb.config);
#  - otherwise the factory menu's stored choice is kept.
switch_state=""
[ -f /sys/class/lzy-aa_cp_switch/switch_state ] && switch_state=$(tr -d '\n' < /sys/class/lzy-aa_cp_switch/switch_state)
if [ -n "$switch_state" ] && [ "$switch_state" != "$(getprop persist.otto.last_switch)" ]; then
	if [ "$switch_state" = "0" ]; then
		setprop persist.ctz.adb.config "usb"
	else
		setprop persist.ctz.adb.config ""
	fi
	setprop persist.otto.last_switch "$switch_state"
fi

if [ "$(getprop persist.ctz.adb.config)" == "usb" ];then
	setprop sys.ly.adb.config "usb"
	setprop sys.ly.usb.config "adb"
	setprop sys.ly.protocol "adb"
	echo "peripheral"  > /sys/devices/platform/soc/4e00000.ssusb/mode
else
	setprop persist.ctz.ly.protocol "rcp"
	setprop sys.ly.usb.config "rcp"
	setprop sys.ly.protocol "rcp"
	setprop sys.ly.adb.config "wifi"
fi

usb_config=`getprop sys.ly.usb.config`
if [ "${usb_config}" == "adb" ];then
	setprop persist.vendor.usb.config "diag,serial_cdev,rmnet,dpl,qdss,adb"
	# OTTO: the USB HAL read the old value earlier in boot; apply now, not one boot later.
	[ "$(getprop sys.usb.config)" != "diag,serial_cdev,rmnet,dpl,qdss,adb" ] && setprop sys.usb.config "diag,serial_cdev,rmnet,dpl,qdss,adb"
elif [ "${usb_config}" == "raa" ];then
	setprop persist.vendor.usb.config "mtp"
else
	setprop persist.vendor.usb.config "rcp"
fi

if [ "$(getprop sys.ly.usb.config)" == "raa" ];then
	ly_fun_raa_init
elif [ "$(getprop sys.ly.usb.config)" == "rcp" ];then
	ly_fun_rcp_init
fi

while :
do
	sync;
	sleep 5;
done
