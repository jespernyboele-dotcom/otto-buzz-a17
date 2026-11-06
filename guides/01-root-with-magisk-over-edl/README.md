# Root with Magisk over EDL (Qualcomm, no fastboot needed)

**Result on OTTO (2026-09):** Magisk 30.7, `su -c id` → `uid=0(root) … context=u:r:magisk:s0`, persistent across reboots
and across the later move to Android 17. Only `init_boot_b` was written; vbmeta, super and the partition table were not touched.

## The idea
On Android 13+ devices with an `init_boot` partition, Magisk patches **init_boot** (the generic ramdisk), not boot.
Instead of `fastboot flash`, we wrote the patched init_boot through Qualcomm's emergency download mode (EDL, USB `05c6:9008`)
with a Firehose programmer. EDL lives in the boot ROM, so it is also the way back if anything goes wrong.

## You need
- A device whose bootloader reports **unlocked**. Check before anything else:
  `getprop ro.boot.flash.locked` → `0`, `getprop ro.boot.verifiedbootstate` → `orange`.
  A locked bootloader will refuse to boot a patched init_boot. This guide does not unlock bootloaders.
- The Firehose programmer that matches **your** SoC and OEM signing (ours: `goco7.bin`, SHA-256 `f7799eb9…`). Not supplied here.
- A way into EDL (OTTO: power off, hold the EDL button, plug USB in, release).
- A host that speaks Sahara + Firehose: a PC with Python/pyusb, or an Android phone in Termux (`termux-usb`). Our reference
  tools are in `../../tooling/edl/r29e-reference/` (`root_reader_R29E_STRICT_READ_ONLY.py`, `root_writer_R29E_proven_reference.py`).
- The official Magisk APK (ours: v30.7, SHA-256 `e0d32d21…`) from topjohnwu/Magisk releases.

## Steps
1. **Read-only first.** In EDL, load the programmer (Sahara), send Firehose `configure`, read the GPT. Find `init_boot_a/_b`
   and note the first/last LBA and size of the one for your **active** slot (ours: `init_boot_b`, 8 MiB).
   Save a hash of the GPT: the writer later refuses to run if the table is not the one you read.
2. **Back up the stock init_boot** (read it out, twice, compare SHA-256). Keep it in two places. This is your rollback.
3. **Patch a copy offline.** Magisk app → Install → "Select and patch a file" → the stock init_boot image (any Android phone
   will do), or `magiskboot` by hand. Check: unpack → repack → unpack of the stock image round-trips before you trust the tool.
4. **Write only that range**, guarded:
   - refuse unless the programmer hash, the GPT hash and the patched image hash are exactly the expected ones;
   - read the live partition first and refuse unless it is **exactly stock** (or exactly patched = already done);
   - write in 1 MiB chunks, keep a ledger (resume after a USB drop), then read **all** of it back and compare the SHA-256;
   - do not touch vbmeta, super or the GPT.
5. Reset. On OTTO adb was not seen right after the reset; don't panic, give it time (and you still have EDL + the backup).
6. Install the Magisk app, let it finish its setup (it may ask to reboot). Verify: `adb shell su -c id`.

## Rollback
Same writer, same guards, with the stock backup as the image. Afterwards the readback must equal the stock SHA-256.

## Tips from OTTO
- System scripts that need root but run before Magisk's PATH is set can use a symlink `/system/bin/su → /debug_ramdisk/su`
  (we added it in our own system image).
- After the move to Android 17 (new system/vendor in super), root stayed: init_boot was never changed.
- We also spent a lot of time on a side route (binary-patching `adbd` for `adb root`). It was **not** needed: Magisk is the way.
- Never run a writer you copied from a phone to a PC without checking its size and SHA-256: an MTP copy truncated one of ours.
