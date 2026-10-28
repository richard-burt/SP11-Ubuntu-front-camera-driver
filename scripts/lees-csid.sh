#!/bin/bash
# Leest de statusregisters van CSID0 uit terwijl er gestreamd wordt.
#
# Dit beantwoordt de vraag die met dmesg niet te beantwoorden is: komt er
# überhaupt signaal binnen op de MIPI-lanes? Staat CSI2_RX_IRQ_STATUS op nul,
# dan ziet de ontvanger niets -- ook geen fouten -- en zendt de sensor dus niet.
# Staat er iets in (al is het een CRC- of ECC-fout), dan zendt hij wel en zit het
# probleem verderop.
#
# Registeroffsets uit camss-csid-680.c; CSID0 zit op 0xacb7000 (reg-names
# "csid0" in de isp-node). CONFIG_IO_STRICT_DEVMEM staat uit, dus MMIO is via
# /dev/mem leesbaar.
set -uo pipefail

timeout 25 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 >/dev/null 2>&1 &
STREAM=$!
sleep 4

python3 - <<'EOF'
import mmap, os, struct, time

BASIS = 0xacb7000          # CSID0
REGS = {
    'TOP_IRQ_STATUS':      0x7c,
    'BUF_DONE_IRQ_STATUS': 0x8c,
    'CSI2_RX_IRQ_STATUS':  0x9c,
    'CSI2_RX_CFG0':        0x200,
    'CSI2_RX_CFG1':        0x204,
}
PAGE = 0x1000
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
try:
    mm = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ,
                   offset=BASIS & ~(PAGE - 1))
except Exception as e:
    print(f'kon CSID-registers niet mappen: {e}')
    raise SystemExit(1)

print('drie metingen met een halve seconde ertussen:')
for ronde in range(3):
    uit = []
    for naam, off in REGS.items():
        v = struct.unpack('<I', mm[off:off + 4])[0]
        uit.append(f'{naam}=0x{v:08x}')
    print('  ' + '  '.join(uit))
    time.sleep(0.5)
mm.close()
os.close(fd)
EOF

wait $STREAM 2>/dev/null
echo "vfe0-irq: $(grep isp_msm_vfe0 /proc/interrupts | awk '{print $2}')"
