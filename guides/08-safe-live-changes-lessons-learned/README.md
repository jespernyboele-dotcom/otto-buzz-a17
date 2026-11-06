# Safe live changes — lessons learned on a device in a car

OTTO is in daily use in a car. These rules come from things that went wrong, or nearly did.

## Before you change anything
- **Check that the car is not moving.** No reboots, no screen tests while someone drives. From adb:
  `dumpsys location | grep -o 'vel=[0-9.]*'` (m/s). We once ran a test at 11.6 m/s. Don't.
- **Know your way back** before the change, not after (guide 02).
- **One change per boot.** Two changes and a black screen = you don't know which one.

## Test from /data before you bake it into the image
- Put the new file in `/data`, and bind-mount it over the system file from an early boot hook
  (`/data/adb/post-fs-data.d/`), **only if its SHA-256 is the one you expect**. Removing the hook and rebooting undoes it.
  Our table-driven hook: `../../attic/superseded/test-hooks/91-otto-final-test.sh` + `table.txt`.
- When it is proven, build it into the image and remove the hook. Then check that no test hooks are left.

## Replacing files on a running system
- **`mv`, not `cp`, for a library that is in use.** `cp` overwrites the bytes that running processes have mapped and
  crashes them; `mv` of a new file swaps the name and leaves the old inode alone.
- Write to `file.new`, `sync`, then `mv file.new file`, `sync`. And `sync` before every reboot.
- Since our last image: fixes ship as **app updates** (`adb install -r`). A new image only for a critical system fix.

## Never
- **No OTA on a modified device.** An OTA to the other slot left OTTO with a black screen; EDL got it back.
- Don't trust "bench PASS" for the car. Keep a list of what is proven where (`../../manifests/FEATURE_STATUS_AND_ACCEPTANCE.tsv`).

## Verify every boot the same way
An on-device script with one line per check makes a post-boot verification you can repeat after every change
(ours: 74 checks, `../../tests/acceptance/postboot_verify_device.sh`):
```sh
chk V57 "bitrate 12 Mbit/s" '[ "$(cat /data/adb/otto/config/recorder_bitrate)" = 12000000 ]'
```
Pitfall we hit: each check runs in its own `sh -c`, so a shell **function** defined in the script does not exist inside it.
Our sha checks all failed falsely until we wrote `sha256sum … | cut -c1-16` inline.

## Little things that cost hours
- adb over Wi-Fi only works when the phone is on the **same** network as the device (not mobile data).
- Copying from phone to PC over MTP can truncate files: hash-check everything that will write to a device.
