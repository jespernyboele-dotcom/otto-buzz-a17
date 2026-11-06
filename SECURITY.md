# Security

- Never commit: keys/keystores, tokens, Wi-Fi credentials, device dumps (GPT, misc, metadata, devinfo), partition images,
  userdata/app data, unredacted logs. `.gitignore` blocks the common file types; it is not a substitute for review.
- Before every push: secret scan of the whole tree and history, large-file check, review of new files.
- Device addresses are written as `<OTTO_IP>`; set your own when running a script.
- Partition-writing tools must keep their guards (hash-bound inputs, typed confirmation, read-back verify).
  No CI job may run adb, fastboot, EDL or signing.
- Report problems to the repository owner directly.
