#!/bin/bash
# Leest tijdens het streamen de C-PHY-statusregisters van CSIPHY4 (0xacec000)
# plus de CSID-ontvangststatus. Alleen draaien terwijl er een stream loopt
# (of laat dit script er zelf een starten): registers lezen met de klokken
# uit hangt de bus.
set -uo pipefail

timeout 20 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 >/dev/null 2>&1 &
STREAM=$!
sleep 3

# Als STREAMON faalde is v4l2-ctl al geëxit en staan de klokken uit;
# /dev/mem-reads hangen dan de bus (harde reset 13 aug). Dus: controleren.
if ! kill -0 $STREAM 2>/dev/null; then
  echo "GEEN LOPENDE STREAM (STREAMON gefaald?) — registers niet gelezen."
  exit 1
fi

python3 - <<'EOF'
import mmap, os, struct

def dump(base, ranges):
    PAGE = 0x1000
    fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
    # CSIPHY-blok is >4K: map 8K vanaf paginagrens
    mm = mmap.mmap(fd, 0x2000, mmap.MAP_SHARED, mmap.PROT_READ,
                   offset=base & ~(PAGE - 1))
    for label, start, count in ranges:
        vals = []
        for i in range(count):
            off = start + 4 * i
            v = struct.unpack('<I', mm[off:off + 4])[0]
            vals.append(f'{v:02x}')
        print(f'  {label} (0x{start:04x}+): ' + ' '.join(vals))
    mm.close(); os.close(fd)

import subprocess
ent = subprocess.run(['media-ctl','-d','/dev/media0','-p'],capture_output=True,text=True).stdout
import re as _re
m = _re.search(r'msm_csiphy(\d)', ent)
BASES = {0:0xace4000, 1:0xace6000, 2:0xace8000, 4:0xacec000}
PHYB = BASES[int(m.group(1))] if m else 0xacec000
print(f'CSIPHY{m.group(1) if m else "?"} @ {PHYB:#x}:')
dump(PHYB, [
    ('trio0 status', 0x340, 8),
    ('trio0 cphy_lane_status', 0x358, 2),
    ('trio1 status', 0x740, 8),
    ('trio1 cphy_lane_status', 0x758, 2),
    ('trio2 status', 0xB40, 8),
    ('trio2 cphy_lane_status', 0xB58, 2),
    ('common status 0x10b0', 0x10b0, 12),
])

print('CSID0 @ 0xacb7000:')
dump(0xacb7000, [
    ('TOP/BUF/RX irq-status', 0x7c, 1),
    ('BUF_DONE', 0x8c, 1),
    ('CSI2_RX_IRQ_STATUS', 0x9c, 1),
    ('RX_CFG0/1', 0x200, 2),
    ('RX_TOTAL_PKTS/CRC', 0x300, 8),
])
EOF

wait $STREAM 2>/dev/null || true
