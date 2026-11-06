#!/usr/bin/env python3
"""OTTO F10b (2026-10-31): stop the OEM lyscrservice (FINAL2 /system/bin/lyscrservice, sha a4e67088...) from rebooting
the box. CScreenServer::doReboot (called after killing other link apps, killall lyLinkApp/carlife) calls
reboot(LINUX_REBOOT_CMD_RESTART) through a Thumb->ARM linker veneer (0xd226c -> reboot@plt 0x3d2c) unless
sys.ly.hdmi.enable is set or /data/ly_debug exists; it ignores persist.ly.no.reboot. The tail call `b.w 0xd226c` at
0x4d0a (after `pop.w {r4, lr}`) becomes `bx lr; nop`: the function returns instead. Usage: patch_lyscrservice.py <in> <out>"""
import hashlib, struct, sys
SRC_SHA = "a4e67088d073cc55"
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, "rb").read())
assert hashlib.sha256(d).hexdigest().startswith(SRC_SHA), "unexpected lyscrservice"
assert struct.unpack_from("<HHHH", d, 0x4d06) == (0xE8BD, 0x4010, 0xF0CD, 0xBAAF), "unexpected code at 0x4d06"
struct.pack_into("<HH", d, 0x4d0a, 0x4770, 0xBF00)        # bx lr ; nop
open(dst, "wb").write(d)
print(hashlib.sha256(d).hexdigest(), dst)
