# Android 17 GSI on a car box, keeping the OEM CarPlay

OTTO went from stock Android 13 to an Android 17 GSI and kept the OEM CarPlay/RCP chain (Ottocast `lylinkservice`,
`lyscrservice`, the car-side keys). Everything was done from an Android phone in Termux; no PC was needed except for EDL later.

## Order that worked
1. **Try it without commitment: DSU.** Boot the GSI as a Dynamic System Update first. Find out what breaks before you replace anything.
2. **Prove your way back** before the point of no return (our "recovery gates"): bootloader fastboot, fastbootd, EDL read. All PASS.
3. **Back up the stock super** (raw dump, gzip, SHA-256, and re-verify the gzip later).
4. **Build a new super** offline (`../../tooling/migration/scripts/build/`):
   - `system_b` = the GSI, extracted ext4, with your changes written by `debugfs`;
   - `vendor_b`, `vendor_dlkm_b`, `system_dlkm_b`, `odm_b` = **byte copies of the running Android 13 partitions** (this is
     what keeps the hardware and OEM services working). On OTTO those already carried two small patches of ours: the
     60 Hz fix in `vendor/lib64/libsdmcore.so` (`mov w16,#30` → `#60`, 2 bytes, in `HWDeviceDRM::PopulateDisplayAttributes`)
     and SELinux additions (`firmware/patches/sepolicy/otto_vendor.cil`). Everything else is Ottocast's;
   - `lpmake` with the device's own layout (ours: super 6 GiB, 3 metadata slots, virtual A/B flag, one dynamic group);
     we dropped `product_b`, `system_ext_b` and `cow` to make room;
   - validate (`lpunpack` round-trip byte-identical), then `img2simg`.
5. Flash super, erase userdata, boot, run an automated post-boot check (ours: `../../tests/acceptance/postboot_verify_device.sh`).

## Changing the image later, safely
- Write files into the extracted ext4 with `debugfs`, and **copy mode, uid, gid and the `security.selinux` label** of the
  file you replace (`patch_system_image.sh`). Read every written file back, run `e2fsck`.
- Keep the other partitions byte-identical and check that they are.
- Produce a file-level diff against the previous image (`../../firmware/build/otto_diff_manifest.py`): ours lists exactly
  the files that changed, nothing else.
- Test each change live first (bind mount from `/data`, see guide 08), only then bake it in.

## What broke on the new Android, and how we fixed it
- **OEM libraries built for the old Android ABI.** The OEM screen service loads `libscreenrecord.so`, which drove
  libgui/libstagefright with Android-13-only calls. We replaced only that library with our own (same C entry points),
  which gets H.264 from Android's own tools instead. See guide 04.
- **OEM services that reboot the box** when a session fails. We patched the `reboot()` calls out of two binaries
  (`../../src/lylink-noreboot/`, byte patches with source and result SHA-256).
- **Too many apps for a small box.** Disabling the ones without a function freed ~315 MB and cut CPU pressure from 20 % to ~8 %.

## Not tested
Going back to Android 13 from Android 17 (the backup exists; no restore was run).
