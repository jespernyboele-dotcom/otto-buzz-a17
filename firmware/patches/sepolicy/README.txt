OTTO SELinux til det endelige build                       23.10.2026
=================================================================
Bygger på Googles UÆNDREDE A17 plat-politik + disse tilføjelser.
K1 (Vector/Xposed-regler) udgår sammen med Vector/Zygisk.

FILER
  otto_plat.cil            -> tilføjes sidst i system_b/etc/selinux/plat_sepolicy.cil
  otto_property_contexts   -> tilføjes sidst i system_b/etc/selinux/plat_property_contexts
  otto_vendor.cil          -> tilføjes sidst i vendor_b/etc/selinux/vendor_sepolicy.cil
  se_compile_test_device.sh  init's kompilering genskabt (køres på OTTO, PORT 2)

REGLER (alle bevist live 23-10 som afvisninger / testmodul)
  1. persist.ctz.adb.config får egen type otto_adb_prop.
     system_app (fabriksmenuen, seinfo otto) må sætte den; systemdomæner
     må læse den (ly_link.sh). Erstatter testmodulets brede regel
     'allow system_app default_prop property_service set'.
  2. Composer: find vendor.qti.qspmhal + læs graphics_config_prop,
     graphics_config_writable_prop, zygote_config_prop (perf-boost ved
     tung sammensætning; composer starter før Magisk).
  3. USB HAL (vendor_hal_usb_qti): læs system_prop.
  Ikke tilladt: system_app -> LY_HU_INFO (default_prop). Intet viser at
  noget mangler uden den.

KOMPILERING (lokalt, secilc, samme argumenter som init; policycap-linjer
fjernet i testkopien fordi den lokale secilc er ældre end A17)
  med -N (som init ved opstart):  vanilla rc=0 1301830 B
                                  OTTO    rc=0 1301991 B   -> OK
  uden -N (neverallow-tjek):      vanilla fejler allerede (180 brud fra
                                  GSI/OEM-blandingen) -> beviser at OTTO
                                  booter med -N. OTTO tilføjer 2 brud:
                                  composer->qspmhal (Qualcomms egen regel)
                                  og USB HAL->system_prop (Treble-regel).
                                  Ingen betydning ved opstart (-N).
  Plat-sha matcher i forvejen ikke precompiled (aa24.. vs 4802..) ->
  OTTO kompilerer allerede politikken ved hver opstart; ingen ændring.

PORT 2 / PORT 1 (på OTTO)
  - se_compile_test_device.sh med OTTO-filerne: rc=0 med OTTOs secilc.
  - Domænet for ly_link.sh: 'ps -AZ | grep ly_link' (skal være et
    systemdomæne / coredomain for at læse otto_adb_prop).
  - Efter flash: 0 afvisninger for composer, USB HAL og fabriksmenu;
    wired/wireless i fabriksmenuen virker uden testmodul.
  - Testmoduler fjernes: otto_test_factory_adb, otto_test_composer_se.

PORT 2 BESTÅET 24-10 (på OTTO, OTTOs egen /system/bin/secilc, init's argumenter, -N):
  vanilla_N rc=0 1302712 B   otto_N rc=0 1302885 B   (se_otto_test.sh)
  ly_link-kæden kører i u:r:magisk:s0 (lylinkservice, otto_rgid).

RETTELSE 24-10 (før build) — erstatter regel 1 ovenfor:
  Imaget HAR allerede persist.ctz.adb.config som otto_ctz_adb_prop (FINAL-R1),
  som system_app må sætte. Den planlagte otto_adb_prop ville være en DUBLET
  i plat_property_contexts (risiko: politikken/egenskaber indlæses ikke ->
  ingen boot). Fjernet (gemt i attic/superseded/sepolicy-v1/).
  Den eneste registrerede egenskabs-afvisning er Ottocasts CarPlay-app
  (com.ap.play, uid 10042, system_app) der sætter LY_HU_INFO (default_prop).
  Testmodulets brede regel (system_app -> hele default_prop) tillader det i
  dag. Nu: egen type otto_ly_hu_info_prop kun for LY_HU_INFO (set: system_app,
  læs: alle domæner) = samme opførsel, smallere.
  PORT 2 på OTTO med de endelige filer: rc=0, 1302880 B.
