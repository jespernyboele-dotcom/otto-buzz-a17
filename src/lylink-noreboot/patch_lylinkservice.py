#!/usr/bin/env python3
"""OTTO F10 (2026-10-31): stop the OEM lylinkservice (FINAL2, sha 1c6dd8c0...) from rebooting the box on its own.
lylinkservice calls libc reboot() from 7 places that ignore persist.ly.no.reboot (switchFunMode via the ly_dev key
monitor, a test-mode path and 5 more) and sets sys.powerctl="reboot,recovery" from one function called by the key
monitor. On 2026-10-31 such a reboot hit mid-drive and the car's GPS was lost. Each of these 8 Thumb-2 BLX
instructions is replaced by `mvn.w r0, #0` (4 bytes, r0 = -1): the program carries on as if the call had failed.
doReboot() (respects persist.ly.no.reboot) is left as is. Usage: patch_lylinkservice.py <in> <out>"""
import hashlib, struct, sys
SRC_SHA = "1c6dd8c02cbcdd0dc51a9f7c7a8e993aeb3fa50b1eceb5d0c722d62eb9817fbb"
SITES = {0x26b4c: 0xb048, 0x2869a: 0xb048, 0x28852: 0xb048, 0x2897c: 0xb048, 0x28aaa: 0xb048,
         0x28bf6: 0xb048, 0x28d36: 0xb048,      # blx reboot@plt
         0x2cb6e: 0xab20}                        # blx property_set@plt ("sys.powerctl", "reboot,recovery")
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, "rb").read())
assert hashlib.sha256(d).hexdigest() == SRC_SHA, "unexpected lylinkservice"
for a, plt in SITES.items():                     # .text: file offset == vaddr (first PT_LOAD at 0)
    h1, h2 = struct.unpack_from("<HH", d, a)
    assert h1 >> 11 == 0b11110 and h2 >> 14 == 0b11 and (h2 >> 12) & 1 == 0, hex(a)
    S = (h1 >> 10) & 1; J1 = (h2 >> 13) & 1; J2 = (h2 >> 11) & 1
    imm = (S << 24) | ((1 - (J1 ^ S)) << 23) | ((1 - (J2 ^ S)) << 22) | ((h1 & 0x3ff) << 12) | (((h2 >> 1) & 0x3ff) << 2)
    if S: imm -= 1 << 25
    assert ((a + 4) & ~3) + imm == plt, hex(a)
    struct.pack_into("<HH", d, a, 0xF06F, 0x0000)
open(dst, "wb").write(d)
print(hashlib.sha256(d).hexdigest(), dst)
