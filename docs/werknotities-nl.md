# 13 aug 21:55: EINDSTAND — webcam af, Windows-fabriekskleuren definitief

De voorcamera is een volwaardige webcam: C-PHY-link (LLP 8704), CSID-
hardwarecrop 3844→3840 (sink-conditie!), GPU-debayer (werkt op 3840),
libcamera+PipeWire ("Built-in Front Camera"), dynamische AE (0x0229 +
geïnverteerde gain), en als kleurprofiel de FABRIEKS-CCMs uit de
Windows-CAMX-tuning (smiapp.yaml = smiapp-windows.yaml; eigen kalibratie
staat ernaast als smiapp-eigen.yaml). Bekend gedrag: eerste seconde
in-regelen; kleurprofiel wisselen alleen met camera dicht.

Open (nice-to-have): AGC-startwaarde slimmer (minder fel begin),
sensorhelper voor smiapp (gain-mapping AE), eGL-debayer-bug bij breedte
3844 upstream melden, dossier + jglathe#74 bijwerken, 3840x2160-modus.

---

# 13 aug 19:00: WEBCAM WERKT — libcamera + PipeWire ("Built-in Front Camera")

Route: libcamera simple-pipeline + software-ISP (GPU-debayer) → PipeWire.
`wpctl status` toont de camera als standaard videobron; PipeWire-apps
(GNOME Camera/Snapshot, Firefox, Chromium) kunnen hem gebruiken.

Wat ervoor nodig was (allemaal in ccs-mod/ccs/):
1. `ccs_enum_frame_size` toegevoegd (mainline ccs heeft die op niet en
   libcamera eist hem — "No image format found").
2. `ccs_get_native_size` genormaliseerd 4040x3088 → 4032x3024 (matrix- vs
   uitleesmaat; de formaat-walk strandde op de pixel_array→binner-mismatch).
3. In `ccs_propagate` het src-formaat vastgepind op 3844x2640: de sensor
   draait altijd onze vaste registertabel, dus meeonderhandelen naar een
   andere maat geeft zwart beeld.
4. H-flip uit (0x0101=0): driver rapporteert SRGGB10 en kent onze tabel
   niet; met flip zou de echte volgorde GRBG zijn → R/G verwisseld.
Boot-persistentie: sp11-camera.service (enabled) draait
camera-prepare.sh (module-guards); update-initramfs gedraaid zodat
modprobe.d-opties ook bij boot gelden. camera-start.sh is nu alleen nog
voor raw testopnames.

Open voor beeldkwaliteit: kleurzweem (uncalibrated.yaml — een
smiapp.yaml/ccm-kalibratie voor de IPA maken), AE/gain-koppeling
(0x0204 geïnverteerd; CCS-exposurecontrol 0x0202 vs onze 0x0229-writes
nog verifiëren), 16:9-modus (3840x2160, imx681_windows) voor videobellen.

---

# 13 aug 18:40: PERFECTE FOTO — echte oorzaak gevonden: GEEN LINE-BLANKING

**DE fix van vandaag: LINE_LENGTH_PCK 7552 → 8704** (ccs-imx681-init.h,
0x0342/0x0343). Met LLP 7552 duurt een sensorregel ~17,5 µs terwijl het
MIPI-pakket (4805 B @ ~2,21 Gbps op één trio) ~17,4 µs kost — vrijwel nul
idle-tijd, dus de ontvanger-FIFO liep periodiek over: 600-byte-blokken
(480 px) weg elke ~100 regels + 130 regels per frame kwijt → de
"husselstroken". Met 8704 (~13% ademruimte, ~16 fps): **exact 2640 records
van 4816 bytes per frame, nul gaten, nul slips — complete nette foto's**
(frames/portret3.png: herkenbaar portret).

Dumpstructuur nu: record = 4816 bytes per regel (4805 payload + pad),
frame = sizeimage = 4816×2640; raw-naar-png.py werkt direct op
/tmp/frame-cphy.raw met frame-index. De CSID-crop (3844→3840) is weer UIT
(payload-only): die decode+crop-route verloor zelf data en is niet nodig.
De WM-frame-mode-poging en de gatenmaskering in de renderer zijn ook
verleden tijd. Wat blijft uit de sessie: PHY-modparam-herlaadguard in
camera-start.sh, stop-diagnostiek ("sp11 csid/vfe stop" in dmesg),
exposure 3100 + dgain 4x, gamma-render.

Open: witbalans/kleur (beeld is groenig — raw zonder WB), analoge gain
(0x0204 geïnverteerd), 2510-vs-2640-raadsel is OPGELOST (was de drop),
libcamera-integratie, dossier + jglathe#74 bijwerken (C-PHY-recept +
LLP-bandbreedte-les + csid/vfe-fixes).

---

# 13 aug ~18:15 (ACHTERHAALD door 18:40): crop-route — eindstand van dat spoor

**Opgelost:**
1. Het "donkere pixelarray" (sectie hieronder) is opgelost — geen
   sensor- of registerprobleem. De hele Windows-diff-sectie hieronder is
   daarmee historisch; de blacklist is al verwijderd.
2. **Diagonale drift opgelost in hardware**: CSID croppt 3844→3840 px
   (camss-csid-680.c: bij breedte 3844 échte RAW10-decode i.p.v.
   payload-only + CROP_H_EN + HCROP 0x550=(3839<<16)|0). Regel = exact
   4800 bytes. VFE-WM blijft in MIPI_RAW-dump-mode; frame-based mode (0)
   geeft altijd IMAGE_VIOLATION (beide width-encodings getest) — laten.
3. **Boot-valkuil gevonden**: phy_qcom_mipi_csi2 laadt bij boot uit de
   initramfs ZONDER modprobe.d-opties (force_cphy=N, cdr=0 → TOTAL_PKTS=0,
   alles lijkt dood). camera-start.sh herlaadt de module nu automatisch.
4. Belichting: exposure 3100, dgain 4x in ccs-imx681-init.h — ccs.ko
   met deze waarden is geïnstalleerd (18:20). Herladen bij gebruik doet
   camera-start.sh niet zelf; na een driverwijziging altijd
   `modprobe -r qcom_camss && modprobe -r ccs` vóór de start.
5. Diagnose voortaan ZONDER /dev/mem: "sp11 csid stop"/"sp11 vfe stop"
   pr_info's bij stream-stop (TOTAL_PKTS, RX_IRQ, IMG_VIOL, readbacks).

**Nog open (cosmetisch/verdieping):**
- Per regel één 15-16-byte nul-gat (positie ≡5 mod 1200, verspringt −1200
  per ~100 regels; frames hebben 2510 echte beeldregels van de 2640).
  raw-naar-png.py maskeert het met de vorige regel. Oorsprong onbekend —
  kandidaten: WM-burst-randgeval in dump-mode, CSID-repack-flush.
- Frame-based WM-mode ooit alsnog werkend krijgen (netter, geen maskering).
- Analoge gain kalibreren (0x0204 geïnverteerd!), witbalans, libcamera.
- Dossier + jglathe#74 bijwerken met dit hele verhaal (C-PHY-recept,
  csid/vfe-fixes, crop-fix — upstream-kandidaten).

Kijkrecept: `pkexec ~/sp11-camera/camera-start.sh 3` →
`python3 raw-naar-png.py /tmp/f1.raw uit.png 0` (f1 = tweede buffer; zie
frames/beeld-schoon.png voor het huidige beste resultaat).

---

# 13 aug 16:30: WINDOWS-REGISTERDIFF KLAARGEZET (het beslissende experiment)

Online onderzoek: djmulder loste op de SP10 zijn donker-beeld op (analoge gain
0x0204 is GEINVERTEERD: hardware 0=16x!) en vraagt zelf om "a register-level
I2C trace from Windows" als missend puzzelstuk. Bij ons bevestigd: CCS-
framelengte 0x0340 leest 0 en weigert writes (zijn SP10-workaround "0x0340
na streamon schrijven" pakt bij ons niet); flip aan/uit maakt niets uit;
chip-ID 0x0004 = 0x0aff klopt met de Windows-SCFG (juiste moduulvariant).

Wij KUNNEN die Windows-trace de facto krijgen: dual boot + warme reboot
bewaart registerstaat. Klaargezet:
- regdump-linux-init.txt — baseline van onze eigen init (16k registers)
- dump-sensor-regs.sh — dumpt CCS 0x0000-0x0fff + vendor 0x3000/0x7000/0xd000
  (i2c max 8 bytes per read op de CCI)
- windows-diff.sh — dump na Windows + automatische diff
- /etc/modprobe.d/cam-dump-blacklist.conf — TIJDELIJK, blacklist ccs zodat de
  eerstvolgende Linux-boot de Windows-staat niet overschrijft. NA DE DUMP
  VERWIJDEREN!
PROCEDURE: boot Windows -> open de Camera-app (beeld zichtbaar!) -> herstart
TERWIJL de app draait (Start > Opnieuw opstarten, geen shutdown) -> Linux ->
pkexec ~/sp11-camera/windows-diff.sh. Als de sensor niet antwoordt waren de
rails toch uit; dan opnieuw met de app aan tijdens de herstart.

---

# 13 aug 16:00: LAATSTE OBSTAKEL — pixelarray blijft donker (link + pijplijn OK)

De frames zijn echt maar bevatten alleen zwartniveau (~64) + temporele ruis.
Systematisch uitgesloten (alles gemeten, niet gegokt):
- ADC/analoog uitleespad DRAAIT: ruis varieert per frame, "hete pixels"
  verspringen — het is geen statische digitale vulling.
- Testpatroon (0x0600=2) komt pixelperfect door: kleurbalken, 4 unieke
  waarden — uitgangsblok + hele link + ISP-keten foutloos.
- MAAR: het beeld is invariant voor ALLES: digitale gain 15x (0x020e=0x0f00,
  readback bevestigd!), analoge gain 0-0x3ff, exposure 1907→5888, licht op de
  lens (lamptest gebruiker: blijft exact 24). De beeldstroom is dus ontkoppeld
  van de pixelpijp die deze registers besturen.
- Rails: alle pm8010-rails + l7b/l3m fysiek aangezet (sp11cam rear/ir +
  ccs-consumer), koude power-cycle in exacte Windows-volgorde gedaan.
- Pin TLMM 237 (Windows: laag→rails→1ms→hoog→10ms): beide standen getest,
  incl. koude init met pin fysiek hoog (gpio-proxy van de jg-kernel drijft
  hem verkeerd om — aparte bug, zie hieronder). Geen effect.
- CCS software-reset 0x0103=1 + verse init: geen effect.
- Volledige Snapdragon-vendortabel (361 regs) teruggezet vóór de
  Gilerson-laag (ccs-imx681-vendor.h, imx681_mode_skip bit2 slaat over):
  geen effect.
- Volledige Windows-registerset (vendor + originele modustabel 3840x2160,
  OP-PLL 2400, imx681_windows=1): symboolrate ~1052 Msym/s krijgt onze
  1p2-AFE-rij niet schoon (beste: 0x803017 bij cdr 0x40) — Gilerson-PLL
  blijft de werkende link.

CONCLUSIE: de sensor leest een uitgeschakeld/afgekoppeld pixelarray uit.
Er ontbreekt iets buiten de sensorregisters om: een moduul-interne power-
schakelaar (bijv. via de tweede die op i2c 0x1a — zelfde model-id, reageert),
een rail die Windows elders zet (platform-INF/ACPI-component, niet in de
CAMF_RES-blob), of een verborgen analoge enable. DIT is de vraag voor
djmulder/jglathe/AndreGilerson: "sensor streamt, link schoon, testpatroon
perfect, maar pixelarray levert alleen zwartniveau en negeert gain/exposure/
licht — wat mist er?"

BUGS BIJVANGST: (1) jg-kernel gpiolib_shared-proxy: gpiod meldt fysiek hoog
terwijl TLMM-pin 237 laag staat — consumer-writes bereiken de pin geïnverteerd/
niet. (2) Metingen "tijdens stream" na frame-succes zijn artefacten: opname is
in <1s klaar en runtime-PM suspendt daarna (eerdere suspend/rails-observaties
herzien).

KNOPPEN: ccs imx681_cphy (0x0111), imx681_windows (volledige Windows-set),
imx681_mode_skip bit2 (vendortabel overslaan). Werkende basis: camera-start.sh.

---

# 13 aug 14:26: DE CAMERA WERKT — eerste frames ooit uit de SP11 onder Linux

Drie frames van 3840x2640 RAW10 (12.672.000 bytes/stuk) opgenomen naar
/tmp/frame-cphy.raw. Echte sensordata (pixelruis, zwartniveau ~64), wel donker
— belichting/gain-tuning is voor later (libcamera; NB analoge gain 0x0204 is
GEINVERTEERD: 0 = max).

## Het werkende recept
- DTB: sp11-denali-cphy-phy2 in de UKI (camera = C-PHY op CSIPHY2, trio 0!)
- phy_qcom_mipi_csi2 force_cphy=1 cphy_trio=0 cphy_rate=0 (1p0Gsps) cphy_cdr=0x4a
  (CDR-venster 0x46-0x4e is schoon: 181k pkts/2s, nul fouten; 0x00/rij-default
  en >=0x52 geven fouten/stilte)
- qcom_camss force_cphy=1 cphy_input=0; ccs imx681_cphy=1 (Gilerson-tabel met
  0x0111=3) — params staan persistent in /etc/modprobe.d/sp11-camera.conf
- pijplijn 3840x2640 (NIET 3844: 4805 bytes/regel is geen 16-veelvoud)
- opstarten + testopname: pkexec ~/sp11-camera/camera-start.sh

## De drie driverbugs die het tegenhielden (allemaal gefixt in updates/)
1. camss-csid-680: RDI_CFG1 zette DROP/CROP-enables terwijl de patroon- en
   cropvensterregisters nooit geschreven worden (reset 0 = alles droppen).
   Fix: enables weg + expliciet keep-all-patronen (zoals csid-gen2).
2. camss-vfe-680: writemaster stond in mode 0 (QCOM_PLAIN, frame-based) →
   IMAGE_VIOLATION bit24 op elke frame. Fix: mode MIPI_RAW (1<<16), zoals
   vfe-480. (Beide fixes zijn upstream-kandidaten voor linux-media!)
3. ccs: X_OUTPUT_SIZE 3844→3840 zodat de regel (4800 bytes) 16-uitgelijnd is.

## Meetgereedschap dat dit vond (bewaren)
- lees-cphy-pakketten.sh — pakkettellers + header-capture csid
- test-cdr-sweep.sh — CDR-venster meten (vers gelatchte IRQ + pkts/2s)
- vind-vcdt.sh — capture-filtersweep (capture rearmt niet betrouwbaar, NB)
- RDIN0-IRQ 0xec: INPUT_SOF/SOL/EOL/EOF vs DROP_* was de doorslaggevende meting

## Openstaand
- Beeld is donker: exposure/gain-tabel afregelen (0x0204 geinverteerd!), dan
  libcamera/pipewire (softISP) — Bayer is GRBG door H-flip 0x0101=1.
- ccs-boot-race (eerste probe faalt op link-freqs) — camera-start.sh vangt op.
- cphy-phy2-DTB mist de BT-fix (local-bd-address); boot-oneshot vangt op, maar
  DTB t.z.t. herbouwen met beide.
- CDR 0x4a robuustheid over temperatuur/reboots in de gaten houden.
- Upstream/community: csid-680- en vfe-680-fixes melden (linux-media, jglathe,
  David Heidelberg C-PHY-reeks — wij zijn de eerste x1e80100-C-PHY-gebruiker),
  dossier-en.md is bijgewerkt.
- Windows-frontcamera bleek dus WEL C-PHY (Snapdragon-bedrading); de
  Intel-SP10/11-D-PHY-conclusie gold alleen voor Intel.

---

# 13 aug (middag): GILERSON-CONFIG DRAAIT — TX is nu bewezen correct, RX nog 0

AndreGilersons imx681.c gevonden (github.com/AndreGilerson/linux-surface-kernel,
branch v7.0-surface-devel, drivers/media/i2c/imx681.c; kopie in ~/sp11-camera/
gilerson/). Zijn tabellen zijn overgenomen in ccs-mod (ccs-imx681-init.h,
39+12 regs, hook vlak voor MODE_SELECT in Gilerson-volgorde init→10ms→exposure;
oude Snapdragon-tabellen vervallen, imx681_mode_skip default nu 0). Src-formaat
3844x2640. min_vt_pix 162→160 in ccs-imx681.yaml zodat de driver 969,6 MHz uit
de DT kiest (geverifieerd: link_frequency-ctrl = 969600000, pixel_rate
387840000). Sensor tijdens stream: 0x0111=2, PLL e1/03·01·2f (= exact
Gilerson), framecounter loopt. test-dphy2.sh bijgewerkt (3844x2640 +
PLL/framecounter-readback).

RESULTAAT: RX_IRQ_STATUS blijft 0 op csiphy2, geen fouten. Ook de CSID-DL-sweep
met de bewezen TX (test-dphy2-dlsweep.sh, alle 12 permutaties) is nul. De
zenderkant is hiermee uitgeput; het gat zit bij de PHY-ontvangst of de bedrading.

BELANGRIJK INZICHT: alle eerdere csiphy-sweeps (11-12 aug) draaiden met de oude
vendortabel toen de sensor vermoedelijk niet echt zond. Alleen csiphy2 is met de
bewezen config getest. KLAARGEZET: sp11-denali-dphy2-phy0/phy1/phy4.dtb
(gebouwd met patch_phy_dphy2.py uit de dphy2-basis) + kies-lane.sh-entries.

SWEEPUITSLAGEN (Gilerson-TX, framecounter liep telkens):
- csiphy2 (dphy2)      : RX 0, geen fouten; ook DL-sweep 12 permutaties nul
- csiphy4 (dphy2-phy4) : RX 0, geen fouten (13 aug 13:35, CFG0 0x00500101 ok)
- csiphy0 (dphy2-phy0) : RX 0, geen fouten (13 aug 13:39, CFG0 0x00100101 ok)
- csiphy1 (dphy2-phy1) : RX 0, geen fouten (13 aug 13:43, CFG0 0x00200101 ok)
SWEEP COMPLEET: alle vier de csiphy's nul met bewezen TX. Maar: de C-PHY-test
van 12 aug zag op csiphy2/trio0 WEL ontvangst (EOT's, SOT-fouten, scherpe
CDR-curve). D-PHY-TX -> overal stilte + C-PHY-TX -> ontvangst op csiphy2 =
de Snapdragon-SP11 is vermoedelijk toch C-PHY-bedraad (de D-PHY-conclusie
kwam van de Intel-toestellen). Gilersons PLL ~970 Msym/s past bovendien
precies bij de sterkste AFE-rij (1p0Gsps) uit die sweep.

KLAARGEZET VOOR DE VOLGENDE REBOOT (cphy-phy2-DTB zit al in de UKI):
C-PHY-herkansing met bewezen sensorconfig: nieuwe ccs-modparam imx681_cphy
(schrijft 0x0111=3 i.p.v. 2, rest Gilerson), test-cphy-sweep.sh zet hem zelf
en is bijgewerkt naar 3844x2640. Na reboot:
    pkexec ~/sp11-camera/test-cphy-sweep.sh
Focus: trio0, rate-rij 0 (1p0Gsps); daarna evt. cphy_cdr 0x52-0x58 fijnmazig.
LET OP: cphy-DTB mist de BT-fix (boot-oneshot vangt dat op); bij wifi-uitval
koud herstarten, GEEN restore. Dossier is bij (dossier-en.md, EN, klaar om te
posten naar jglathe#74 / linux-surface#2153 / David Heidelberg als ook dit
niets geeft).
NB: de ccs-boot-race trad op na de phy4-reboot; herladen (modprobe -r ccs;
modprobe ccs) volstond.

VOLGENDE ACTIE (per phy één reboot):
    pkexec ~/sp11-camera/kies-lane.sh dphy2-phy4   # of -phy0 / -phy1
    reboot
    pkexec ~/sp11-camera/test-dphy2.sh
csiphy4 eerst: alle x1e80100-laptops met werkende camera zitten daar.
Daarna terug naar dphy2 (csiphy2) als beste kandidaat als alles nul blijft, en
dan het dossier naar jglathe/djmulder/linux-surface (#2153) — TX-bewijs is rond.

# 13 aug (ochtend): D-PHY-stand — zie memory sp11-audio-en-camera (bovenste blok)
UBSAN-trace bij elke ccs-probe gefixt: float_to_u32_mul_1000000 in
ccs-reg-access.c shiftte met -exp>=64 (denormaal register van de IMX681);
nu begrensd (return 0). Fix zit in ccs-mod en de geïnstalleerde updates/ccs.ko.
Actief: dphy2-DTB (csiphy2, D-PHY 2-lane), ccs met imx681_mode_skip=3,
camss met dl_map-param. Sensor zendt D-PHY 998,4 MHz, RX nul.
EERSTE ACTIE VOLGENDE SESSIE: AndreGilersons imx681.c (Intel-SP11) zoeken op
GitHub en zijn init/modus-tabellen in ccs-mod overnemen; daarna link 969,6
mogelijk maken (min_vt_pix iets verlagen in ccs-imx681.yaml).

# ALLERNIEUWSTE STAND (12 aug, 16:30): C-PHY op CSIPHY4 volledig uitgeput

De echte laneprogrammering zit in `phy_qcom_mipi_csi2` (losse PHY-driver), niet
in camss — bron + patches in `~/sp11-camera/phy-mod/`. C-PHY draait daar nu
met de exacte downstream-volgorde; alles runtime-instelbaar:
  phy: force_cphy, cphy_trio (0-2), cphy_rate (0-7 = 1p0..2p5 Gsps)
  camss: force_cphy, cphy_input (CSID DL0-ingang)
Sensor zendt bewezen C-PHY (0x0111=3, framecounter loopt) — maar RX blijft 0
op alle trio/rate/input-combinaties op CSIPHY4. Geen hangs meer.
Meetscript: `lees-cphy-status.sh` (alleen draaien terwijl de stream loopt!).

Volgende opties: (a) csiphy0/1/2 in C-PHY-modus (per phy een DTB + reboot;
patch_phy.py-varianten hebben bus-type/phy-type-aanpassing nodig), (b) het
dossier voorleggen aan David Heidelberg (camss C-PHY WIP v4), jglathe en
linux-surface. Zie memory `sp11-audio-en-camera` voor het volledige verhaal.

---

# NIEUWSTE STAND (12 aug 2026, middag): C-PHY-herkansing staat klaar

Online onderzoek (twee zoekagenten) leverde op:
- C-PHY-hypothese bevestigd: CCS-register 0x0111=3 is per spec "CSI-2 C-PHY";
  mainline camss kan op géén enkele SoC C-PHY ontvangen. Niemand heeft de
  SP11-camera's onder Linux werkend (ook de Intel-SP11 niet).
- Onze 2.1.2-registertabel was WÉL de juiste generatie: mainline stuurt de
  x1e80100 met exact die tabel (D-PHY-deel byte-identiek), en 0x40010000 is
  gewoon de rev-id die elke X Elite meldt. De 3ph-tabel is stabiel over
  2.1.x–2.2.x. Downstream heeft geen hamoa-target; selectie gaat daar via
  DT-compatible, nooit via een versieregister.
- De bus-hang kwam vrijwel zeker door ons CTRL5-masker: wij schreven BIT(0),
  maar C-PHY gebruikt de ONEVEN bits (BIT(pos*2+1), trio 0 = BIT(1)) zonder
  CLK_ENABLE — bron: patch 2/9 van "media: camss: Add support for C-PHY
  configuration" (David Heidelberg, WIP v4, feb 2026, mail-archive
  msg2613894/msg2613897). Lane-blok ongeklokt beschrijven hangt de bus.
- Gefixt in camss-jg (get_lane_mask + lanes_enable), gebouwd en geïnstalleerd
  in updates/: srcversion 2DD23F6F3E322F9128131D6. force_cphy=0 blijft
  gedragsgelijk aan de in-tree module.

## De test (één reboot)
    pkexec ~/sp11-camera/kies-lane.sh cphy      # cphy-DTB in de UKI
    reboot
    pkexec ~/sp11-camera/test-cphy.sh           # sanity -> force_cphy=1 -> meting
Let op: de cphy-DTB mist de local-bd-address-BT-fix van sp11-denali-bt.dtb;
de btmgmt-boot-oneshot vangt dat op. Bij een hang: hard uit, even wachten
(WCN7850), aan; daarna NIET patch-uki-dtb.sh restore doen tenzij je de
camera-DT bewust kwijt wilt.

Openstaande onzekerheid: de datarate-AFE-rij (1p2Gsps, ~1052 Msps) is mogelijk
niet de juiste voor onze symboolrate; voor "is er ontvangst?" zou de statische
tabel + juiste trio-enable al genoeg moeten zijn.

Fallback als C-PHY niets geeft: dossier voorleggen aan David Heidelberg /
linux-media (wij zouden de eerste x1e80100-C-PHY-gebruiker zijn) en aan
jglathe/linux-surface. De IMX681 kán ook 2-lane D-PHY (Leopard Imaging-module),
maar dat is al getest (cam9) en de bedrading is vermoedelijk C-PHY.

---

# Waar we waren — cameratest via een gepatchte UKI (11 aug 2026)

## Waarom deze omweg
De kernel is een Unified Kernel Image met 18 `.dtbauto`-secties; de EFI-stub kiest
daaruit zelf de DTB en negeert álles wat GRUB of kexec aanlevert. Zie memory
`sp11-dtb-wisselen` voor de drie doodlopende pogingen — niet opnieuw proberen.

Daarom is de Surface-DTB-sectie in de image zelf overschreven met een slanke
cam-DTB (zonder `__symbols__`, past in de 214646 van de sectie).

**Poging 1 sloopte de wifi.** Een toegevoegde `ldo16` op 2,9 V lag niet op het
rpmh-spanningsraster (pldo: 1504000 + n×8000 µV) → EINVAL → de probe van de héle
pm8550-bank faalde, en dat is de PMIC van de wifi-rails. Poging 2
(`sp11-denali-cam2.dtb`, gebouwd met `patch_dts_v2.py`) raakt de pm8550 niet meer
aan — geverifieerd byte-identiek — en corrigeert pm8010 `ldo2` naar 1152000 µV.

## Terugdraaien
    pkexec ~/sp11-camera/patch-uki-dtb.sh restore    # daarna rebooten
    pkexec ~/sp11-camera/patch-uki-dtb.sh status     # wat zit er nu in de sectie
Backup: `/boot/uki-backup/vmlinuz-7.2-rc5-jg-0sp11v3-qcom-x1e.orig` (13 aug
verplaatst: in /boot zelf maakte update-grub er een default-entry zonder initrd
van -> panic "unable to mount root fs on unknown-block(0,0)").
Boot de gepatchte kernel niet: kies in GRUB 'Advanced options' de stock kernel
7.0.0-22-qcom-x1e — dat is een apart image en is onaangeroerd.

## Stand van de DTB-versies
- v2 `sp11-denali-cam2.dtb` — cci aan + pm8010. Wifi bleef staan. Vond de EEPROMs.
- v3 `sp11-denali-cam3.dtb` — + pm8550 ldo7/ldo16 (2904000 uV, op het raster).
  Vond daarmee ook de VCM op 0x0c bij de achtercamera.
- v4 `sp11-denali-cam4.dtb` — + alle vier de CCI-bussen van 1 MHz naar 400 kHz.
  Reden: EEPROM en VCM verdragen 1 MHz, een OV13858 doorgaans niet.

Afgevinkte hypotheses (niet opnieuw proberen):
- MCLK-frequentie: Windows gebruikt ook 19200000 Hz, en debugfs bevestigt dat de
  klok fysiek loopt (enable=1 op zowel cam_cc_mclk1_clk als zijn _src).
- Titan-GDSC: staat aan (pm_genpd_summary).
- cpas_ahb op 80 MHz zoals Windows: toegevoegd aan sp11cam.ko, verandert niets.
- Reset-GPIO's: pin 109/110/237 zijn als GPIO gemuxt en geclaimd.

## Na de reboot: eerst controleren of de nieuwe DT écht draait
    ls -l /sys/firmware/fdt                                    # ~169400, niet ~215200
    tr -d '\0' < /proc/device-tree/soc@0/cci@ac15000/status     # moet 'okay' zijn
    ls -d /proc/device-tree/sp11-cam-probe

## Gereedschap dat je meteen wilt gebruiken
    pkexec ~/sp11-camera/ccs-debug.sh kort     # volledige PLL-redenering van ccs.ko
Dynamic debug geeft per link-frequentie welke deler/vermenigvuldiger gekozen wordt
en welke grens sneuvelt. Elk experiment kost daarmee seconden, geen reboot:
YAML aanpassen -> `cd ccs-tools && ./ccs-yaml-to-bin -s -o ../ccs-sensor-4260-0681-0010.fw ../ccs-imx681.yaml`
-> in /lib/firmware/ccs/ zetten -> ccs herladen.

## Eerst meten, dan pas overschrijven
`min/max_op_sys_clk_div` (0x1160/0x1162) is als enige nooit gemeten, en uit de
trace blijkt dat juist die de doorslag geeft. Meten vereist v5 (daar voedt sp11cam
de voorcamera nog): `patch-uki-dtb.sh` op cam5 zetten, rebooten,
`pkexec env BUS=3 ~/sp11-camera/lees-limieten.sh`.

Gegokte limieten maakten het steeds erger. Houd ccs-imx681.yaml bij de vier
bewezen reparaties; de experimenten staan in ccs-imx681-experimenten.yaml.

## Huidige toestand (einde sessie 11 aug 2026)
Kernel gepatcht met **v7** (`sp11-denali-cam7.dtb`), wifi werkt.
Actief: camera-DT, alle rails, CCI op 400 kHz, MCLK-pinnen gemuxt, camss +
csiphy4 aan (`/dev/media0` bestaat), sensornode `camera@10` op cci1 bus 1.
Statische data in `/lib/firmware/ccs/ccs-sensor-4260-0681-0010.fw` met de vier
bewezen limietreparaties.

Sensoren (busnummering met v7): voor = i2c-4 0x10 en 0x1a = **IMX681**
(sensor_model_id 0x0681), IR = i2c-0 0x60 = **ST VD55G0** (registers 0..3 lezen
omgekeerd als ASCII "S5G0"), achter = i2c-2 0x0c (VCM) + 0x10, nog niet
geïdentificeerd en aan een haperende CCI-master.

`ccs.ko` bindt zich nog niet: de PLL-rekenaar wijst elke link-frequentie af.
Zie memory `sp11-audio-en-camera` voor de volledige trace-analyse.

## Als dat klopt
    pkexec modprobe sp11cam
    ls /sys/bus/platform/drivers/sp11cam/sp11-cam-probe/        # front, rear, ir
    pkexec sp11-cam-scan                                        # scant de 4 CCI-i2c-bussen

Doel: welke sensor zit op welke bus en welk adres. Dat zijn de laatste ontbrekende
gegevens voor echte sensornodes in DT. Realistisch doel is de achtercamera
(OV13858), zie memory `sp11-audio-en-camera`.

## Let op bij kernel-updates
Een nieuwe kernel overschrijft de patch. Na elke kernelinstallatie opnieuw
`patch-uki-dtb.sh patch` draaien, of accepteren dat de camera-DT weg is.

## Doodlopende sporen
- ACPI `_CRS` van MSHW0490/0491/0492 uitlezen voor bus+adres: kan niet. De kernel
  boot in DT-modus dus `/sys/firmware/acpi/tables` bestaat niet, en `/dev/mem` naar
  de RSDP (0xd57be018) wordt geweigerd door `CONFIG_STRICT_DEVMEM`.
- De Windows-blobs bevatten géén i2c-adres of busnummer.
