OTTO A17 — EGNE OTA-OPDATERINGER (Virtual A/B)          23.10.2026
=================================================================

IDÉ
Det endelige build er den sidste EDL-flash. Bagefter installeres nye
versioner fra Android selv: update_engine skriver til den anden slot
mens OTTO kører (ændringer gemmes i /data), næste opstart prøver den nye
slot, og fejler den, går bootloaderen selv tilbage til den gamle.

FAKTA (fra OTTO og det nuværende A17-image)
  [BEVIST] Virtual A/B med kompression: ro.virtual_ab.enabled=true,
           compression/xor/userspace.snapshots=true.
  [BEVIST] Bootloader ulåst (flash.locked=0, orange).
  [BEVIST] I system_b.img: /system/bin/update_engine, snapuserd,
           update_verifier, /system/etc/init/update_engine.rc,
           /system/etc/security/otacerts.zip (Googles nøgler).
  [BEVIST] MANGLER i GSI'en (user-build): update_engine_client og
           snapshotctl -> derfor otto_ota.dex.

FILER HER
  otto_ota.x509.pem   Offentligt OTTO OTA-certifikat (RSA 4096, til 2056).
                      SHA-256 BA:A1:C4:AA:9C:DE:88:29:99:3C:0A:B8:75:EF:
                      AD:30:4A:F0:E1:BC:20:84:24:B7:12:1E:2E:C7:91:54:B8:4C
  otacerts.zip        Erstatter system/etc/security/otacerts.zip i det
                      endelige build (kun OTTO-nøglen).
  otto_ota.dex        OTA-klient (app_process, root). Lægges i
                      system/etc/otto/otto_ota.dex.
                      apply <zip> | cancel | reset | cleanup
  otto_ota_install.sh Kopierer zippen til /data/ota_package og kører apply.
  ota_probe.sh        PORT 1-test på nuværende A17 (læser kun).
  src/                Kildekode (OttoOta.java + stubs til kompilering).

PRIVAT (aldrig i git, aldrig i XDA-opslag)
  ~/OTTO/keys/ota/otto_ota.key  — signerer payload.bin.
  Mistes den, kræver næste opdatering EDL/fastboot igen.
  Til CI: GitHub-secret OTTO_OTA_KEY (base64).

SÅDAN LAVES EN OTA (CI, ubuntu)
  1. Input: de færdige images for HVER A/B-partition, ikke kun super:
     system, vendor, odm, system_dlkm, vendor_dlkm (dynamiske) +
     boot, init_boot (Magisk-patchet, så root overlever), vendor_boot,
     dtbo, vbmeta, vbmeta_system + alle firmware-partitioner med _a/_b.
     Grund: slot _a indeholder i dag A13-firmware/kerne. En OTA der kun
     har system/vendor ville boote A13-kerne med A17-system -> fejl ->
     rollback. Første OTA skal derfor være FULD (alle _b-partitioner,
     læst fra OTTO med dd). ota_probe.sh lister dem med størrelse.
  2. META/dynamic_partitions_info.txt: super 6442450944, gruppe
     qti_dynamic_partitions (max 6438256640), virtual_ab=true,
     virtual_ab_compression=true.
  3. delta_generator / brillo_update_payload fra AOSP otatools
     (x86_64 -> kun i CI, ikke på telefonen) laver fuld payload.bin,
     signeret med OTTO_OTA_KEY.
  4. Zip (payload.bin GEMT, ikke komprimeret + payload_properties.txt).

ÅBNE PUNKTER [PORT1] — skal bevises før buildet låses
  a) ota_probe.sh: update_engine kører, boot-HAL findes, klienten kan
     tale med update_engine (reset).
  b) Signaturtjek: en test-OTA signeret med OTTO-nøglen AFVISES på
     nuværende A17 (Googles otacerts) -> beviser at kæden når til
     signaturtjek. I det endelige build skal samme pakke godkendes.
  c) Fuld test efter flash: OTA til slot _a, genstart, boot på _a,
     merge færdig, og en bevidst ødelagt OTA falder tilbage til _b.
  d) Hentning af otatools i CI (ci.android.com otatools.zip eller
     bygget fra AOSP) — ikke valgt endnu.

PORT 1 a) BESTÅET 24-10 (ota_probe.sh på nuværende A17):
  slot _b, boot-HAL android.hardware.boot@1.2 (QTI), update_engine kører,
  Virtual A/B + kompression + userspace snapshots, /data/ota_package
  (ota_package_file) findes. otto_ota.dex 'reset' -> update_engine
  modtog og nulstillede ("Slot switch reset successful").
  otacerts.zip i dag: kun GSI-nøglen (prod/platform/gsi/q_developer).
  A/B-partitioner med _a (skal i fuld OTA): abl bluetooth boot cmnlib64
  cmnlib devcfg dsp dtbo featenabler hyp imagefv init_boot keymaster mdtp
  mdtpsecapp modem multiimgoem qupfw recovery rpm tz uefisecapp vbmeta
  vbmeta_system vendor_boot xbl xbl_config (+ dynamiske i super).
