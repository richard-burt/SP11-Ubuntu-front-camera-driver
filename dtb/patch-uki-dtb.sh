#!/bin/bash
# De kernel is een UKI met .dtbauto-secties; de EFI-stub kiest daaruit zelf de
# DTB en negeert wat GRUB of kexec aanlevert. Daarom overschrijven we de
# Surface-DTB ín de image. De sectie blijft even groot; alleen de inhoud wijzigt.
#   patch-uki-dtb.sh patch|restore|status
set -uo pipefail
# KVER is overschrijfbaar (kernel-postinst-hook geeft de nieuwe versie mee).
KVER=${KVER:-7.2-rc5-jg-0sp11v3-qcom-x1e}
IMG=/boot/vmlinuz-$KVER
# In een submap: update-grub zag /boot/vmlinuz-*.orig als aparte kernel zonder
# initrd en maakte die de default -> panic "unable to mount root fs".
BAK=/boot/uki-backup/vmlinuz-$KVER.orig
NEW=/home/jeroen/sp11-camera/sp11-denali-cphy-phy2.dtb

case "${1:-status}" in
  patch|restore|status) MODE=$1 ;;
  *) echo "gebruik: $0 [patch|restore|status]" >&2; exit 2 ;;
esac

if [ "$MODE" = restore ]; then
  if [ ! -f "$BAK" ]; then echo "Geen backup op $BAK" >&2; exit 1; fi
  cp -a "$BAK" "$IMG"; sync
  echo "Originele kernel-image teruggezet."
  MODE=status
fi

if [ "$MODE" = patch ]; then
  # Bluetooth: de WCN7850 heeft een geldig BD-adres uit de DT nodig
  # (local-bd-address; zonder komt hci0 op als DOWN RAW). Injecteer het
  # adres in ELKE variant die we installeren, zodat een camera-DTB nooit
  # meer stilletjes bluetooth sloopt. Idempotent (fdtput overschrijft).
  BTTMP=$(mktemp /tmp/sp11-dtb.XXXXXX)
  cp "$NEW" "$BTTMP"
  if ! fdtput -t bx "$BTTMP" /soc@0/geniqup@ac0000/serial@a98000/bluetooth \
       local-bd-address d5 a3 12 7f 03 02 2>/dev/null; then
    dtc -I dtb -O dtb -p 256 -o "$BTTMP" "$NEW" 2>/dev/null
    fdtput -t bx "$BTTMP" /soc@0/geniqup@ac0000/serial@a98000/bluetooth \
       local-bd-address d5 a3 12 7f 03 02 || {
      echo "WAARSCHUWING: local-bd-address injecteren mislukt; DTB ongewijzigd gebruikt" >&2
      cp "$NEW" "$BTTMP"; }
  fi
  NEW=$BTTMP
  trap 'rm -f "$BTTMP"' EXIT

  if [ ! -f "$BAK" ]; then
    cp -a "$IMG" "$BAK"
    echo "Backup gemaakt: $BAK"
  else
    # Altijd vanaf de schone backup patchen. Anders krimpt de beschikbare ruimte
    # naar de grootte van de vórige vervanger, want die bepaalt wat we op deze
    # offset aantreffen.
    cp -a "$BAK" "$IMG"
    echo "Vertrokken vanaf de schone backup."
  fi
fi

python3 - "$IMG" "$NEW" "$MODE" <<'EOF'
import struct, sys, hashlib
img_path, new_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
TARGET_MODEL = b'Microsoft Surface Pro 11th Edition (OLED)'

data = bytearray(open(img_path, 'rb').read())

def fdt_model(buf, off, total):
    # /model staat als property in de structblok; simpel zoeken volstaat hier,
    # want we controleren daarnaast op magic + plausibele totalsize.
    return TARGET_MODEL in buf[off:off+total]

hits = []
i = 0
while True:
    i = data.find(b'\xd0\x0d\xfe\xed', i)
    if i < 0:
        break
    if i + 40 <= len(data):
        total, _, _, _, ver, _ = struct.unpack_from('>IIIIII', data, i+4)
        if ver in (16, 17) and 1024 < total < (4 << 20) and i + total <= len(data):
            if fdt_model(data, i, total):
                hits.append((i, total))
    i += 4

if len(hits) != 1:
    print(f'AFGEBROKEN: {len(hits)} secties met model "{TARGET_MODEL.decode()}" gevonden, verwacht precies 1')
    for off, total in hits:
        print(f'  offset 0x{off:08x} size {total}')
    sys.exit(1)

off, total = hits[0]
cur = bytes(data[off:off+total])
print(f'Surface-DTB in image: offset 0x{off:08x}, {total} bytes, md5 {hashlib.md5(cur).hexdigest()[:8]}')

new = open(new_path, 'rb').read()
newtotal = struct.unpack_from('>I', new, 4)[0]
print(f'Vervanger: {len(new)} bytes (header zegt {newtotal})')

if mode == 'status':
    sys.exit(0)

if len(new) != newtotal:
    print('AFGEBROKEN: bestandsgrootte wijkt af van de FDT-header'); sys.exit(1)
if len(new) > total:
    print(f'AFGEBROKEN: past niet ({len(new)} > {total})'); sys.exit(1)

before = len(data)
# Nieuwe DTB neerzetten en de rest van de sectie nullen, zodat er geen resten
# van de oude boom achterblijven. De sectiegrootte zelf blijft ongewijzigd.
data[off:off+total] = new + b'\x00' * (total - len(new))
assert len(data) == before, 'imagegrootte mag niet veranderen'

open(img_path, 'wb').write(data)
print(f'Gepatcht. Imagegrootte ongewijzigd: {len(data)} bytes')
EOF
rc=$?
[ $rc -ne 0 ] && exit $rc

sync
chmod 600 "$IMG"; chown root:root "$IMG"

# De losse DTB-bestanden doen niets meer (de stub negeert ze), dus zet de
# originele terug zodat het systeem niet onnodig afwijkt.
if [ -f /boot/sp11-denali.dtb.orig ]; then
  cp -a /boot/sp11-denali.dtb.orig /boot/sp11-denali.dtb
  echo "/boot/sp11-denali.dtb teruggezet op het origineel."
fi
sync
echo "Klaar."
