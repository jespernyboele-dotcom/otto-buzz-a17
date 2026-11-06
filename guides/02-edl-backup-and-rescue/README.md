# EDL backup and rescue — the lifeline that always works

On Qualcomm devices the boot ROM's emergency download mode (EDL, USB `05c6:9008`) works even when nothing else boots.
On OTTO it rescued a device that an OTA had left with a black screen, and it flashed every later image.

## Set up once (Windows PC)
1. Python 3, `pip install pyusb libusb-package`.
2. Put the device in EDL; in Zadig install **WinUSB** on the `QUSB__BULK` device.
3. Keep the Firehose programmer for your device next to your tools, and its SHA-256 in a text file.
4. Every script you copy from a phone: check `certutil -hashfile <file> SHA256` against the hash you wrote down.
   A truncated script may exit without a word.

## Back up before you change anything
- Read the full partition table and **every** partition you might ever touch (boot chain, vbmeta, super, misc, persist,
  calibration/key partitions such as our `privdata1` with the CarPlay keys). Hash each file, store two copies off the device.
- Write down which slot is active (`getprop ro.boot.slot_suffix`).

## Rescue order (from our runbook, `../../docs/recovery/EDL_RECOVERY_RUNBOOK.md`)
1. **Android boots?** Do nothing in EDL. Use adb.
2. **Doesn't boot →** EDL, then a **read-only diagnose**: GPT, slot attributes, `misc` (bootloader message), update state.
   Copy the result off and look before writing anything.
3. Wrong slot active, or an update pending → a *targeted* fix of only those bytes (our `setslot-b` was bound by SHA to that
   day's dump and refused any other state).
4. Right slot, broken Android → re-flash super from a known-good image.

## A safe super writer (what ours does, `../../tooling/edl/final3/` and `../../firmware/final3/`)
- `selftest`: expands the sparse image on the PC and checks its SHA-256. No device needed.
- `preflight`: Firehose OK, GPT matches, no writes.
- `flash` (typed confirmation): for each MiB, read first and **skip identical ones**, write the rest, read back each written
  MiB, finally read the whole partition and compare with the image SHA. A ledger file lets it resume after a USB drop.
  Restarting from scratch means deleting the ledger, or it reports "done".

## Never
- No OTA / `update_engine` on a modified device. An OTA to the other slot is what left OTTO with a black screen.
- No `wipe-userdata` unless you mean it.
- No writes from a script you did not hash-check. No writes without a backup you have read back.
