#!/bin/sh
# Reproducible build of libscreenrecord.so R6 (32-bit ARM, Thumb) on the Pixel (Termux clang 21.1.8).
# Links against OTTO's own 32-bit libc.so / liblog.so (copied read-only from the running FINAL2 box into devlibs/,
# from /apex/com.android.runtime/lib/bionic/libc.so and /system/lib/liblog.so), so symbol versions match the target.
# Usage: sh build_r6.sh [out.so]
set -e
cd "$(dirname "$0")"
CC=/data/data/com.termux/files/usr/bin/clang
"$CC" --version | head -1
"$CC" --target=armv7a-linux-androideabi29 -O2 -mthumb -nostdlib -shared \
  -Wl,-soname,libscreenrecord.so -Wl,-z,now -Ldevlibs \
  -o "${1:-libscreenrecord_r6.so}" otto_screenrecord_a17_r6.c -lc -llog
sha256sum "${1:-libscreenrecord_r6.so}"
