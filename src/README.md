# src — what runs on OTTO (FINAL3 R2 + launcher v21b)

Only the version that is in the running image is kept here. Checked 2026-11-06 against the files inside
`system_b.final3.img` (debugfs dump + SHA-256): every file below is byte-identical to the image, except where noted.
Older versions and things that were never used are in `../attic/`.

| Here | In the image | Note |
|---|---|---|
| `boot/run.sh`, `boot/post-fs-data.d/*`, `boot/service.d/*` | `/system/etc/otto/boot/…` | boot tuning: HWC virtual display, GPU 465 MHz, display2/cnss/crash-loop off, fast boot |
| `system-bin/otto_firstboot.sh` | `/system/bin/otto_firstboot.sh` (`4fa81843…`) | identical except one comment where the Wi-Fi names are redacted |
| `system-bin/ly_link.sh` | `/system/bin/ly_link.sh` | OEM CarPlay start wrapper |
| `recorder/` (R8) | `/system/lib/libscreenrecord.so` (`fa8c668f…`) | built with `build_r8.sh`; see guide 04 |
| `lylink-noreboot/` | `/system/bin/lylinkservice` (`9b3b76b5…`), `lyscrservice` (`8c727747…`) | byte patches of the OEM binaries (the binaries are not here) |
| `navi/otto_navi.sh`, `navi/start.sh`, `navi/profiles/mib4.conf` | `/system/etc/otto/navi/…` | NAVI supervisor; see guide 09 |
| `navi/engine/` | `otto_aanav.jar`, `otto_rgid` | Android Auto client + converter, route-guidance engine |
| `navi/cargps/` | `otto_cargps.jar` (`84d5e592…`) | car GPS bridge with satellite extras; `build_cargps.sh`; see guide 05 |

Also in the image, from elsewhere: SELinux additions and init `.rc` files (`../firmware/patches/`), the overlays
(`../firmware/patches/overlays/`), launcher v18 + OTTO Spotify 1.2 (own repository; v21b runs on top as an app update).

In the image, but the source is **not** in this repository: `otto_abridge`, `otto_audio_bridge.sh`, `otto_health.sh`,
`otto_nav_bridge.sh`/`otto_navbridge` (the old notification bridge, paused), `otto_usb0_route.sh`, `ottoctl`,
`ly_link_app.sh`, `otto_scrcpy_server.jar` (upstream scrcpy server).
