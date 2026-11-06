# Third-party and secrets review

Scope: the 80 candidate source files in `SOURCE_HASH_MANIFEST.sha256` + the top-level archive (`ARCHIVE_INVENTORY.tsv`).

## Scan of the 80 candidate files (2026-10-25)
| Pattern | Hits | Action before staging |
|---|---|---|
| GitHub tokens, private key blocks, `password=` | 0 | — |
| Private LAN IP `<OTTO_IP>` | 12 files (migration scripts, postboot verify, recovery gates) | replace with `<OTTO_IP>` |
| Wi-Fi `SSID=`/`PSK=` | `otto_firstboot.sh` — template/parser only (`<name>`, `<passphrase>`) | keep |
| GPS coordinates, serials, IMEI, VIN, e-mail | 0 | — |
Scanner: grep regexes (no trufflehog/gitleaks available offline). A real secret scanner must run on the staged tree before any push.

## Never upload (found on disk)
| Item | Class |
|---|---|
| `Download/github-recovery-codes.txt` | GitHub recovery codes, **plain text in Download** (not opened). Owner should move it to a password manager. |
| `~/OTTO/keys/` (incl. `ota/otto_ota.key`) | signing key |
| `~/OTTO/LAUNCHER/.otto_private_signing/`, `…/key/otto_final_r1_app.jks`, `~/.android/debug.keystore`, `~/.ssh/id_ed25519`, `~/.config/gh/hosts.yml` | keys / tokens |
| `/metadata/otto/provision/wifi.conf` (on device) | Wi-Fi credentials |
| `OTTO_RESCUE/DIAG_*` (gpt, misc, devinfo, metadata, super head) | device-unique data |
| every `.img/.simg/.raw/.img.gz`, `~/OTTO/OTA_BASE_B_20261025`, `~/otto_final_build/work`, migration `01_BACKUPS` (A13 super, boot chain, **a17_userdata_state app data**) | firmware / personal data |
| `goco7.bin` | Qualcomm Firehose programmer (proprietary) |
| Ottocast binaries/APKs: lylinkservice, lyscrservice, mylink, LYFactoryTools (+ `final_build/private/…decoded_src.tar.gz`), patched `libsdmcore.so` | OEM proprietary |
| Google: GSI, GMS, Maps, Android Auto, WebView APKs | proprietary |
| raw logs/bugreports with IP, locations (`otto_car_car1.txt` has a GPS fix), USB IDs | personal data — excerpts only, redacted |

## Third-party code that may be included with attribution
| Component | License | Note |
|---|---|---|
| Femto launcher (upstream of OTTO OEM++) | Apache-2.0 (LICENSE in repo) | keep NOTICE + upstream commit (`OTTO_UPSTREAM_COMMIT.txt`) |
| scrcpy-server 4.1 | Apache-2.0 | prefer link to the upstream release + sha over committing the jar |
| Breezy Weather (LGPL-3.0), HeliBoard (GPL-3.0), AdAway (GPL-3.0) | copyleft | do **not** commit APKs; document versions + upstream links |
| Magisk 30.7 | GPL-3.0 | link only |
| qcom-image-loader | upstream license file in repo (verify before any fork publish) | superseded; optional |

## Visibility
Existing repo `otto-femto-oempp-stage3` is PRIVATE. Any new repo: PRIVATE by default. Public only after this review is re-run
on the staged tree and the owner approves name and visibility. Private is not a substitute for removing secrets.
