#!/bin/bash
# Dump de IMX681-registerbanken via i2c (voor de Windows-vs-Linux-diff).
# Gebruik: dump-sensor-regs.sh <uitvoerbestand>
# Leest CCS-blok 0x0000-0x0fff en vendorblokken 0x3000-0x3fff, 0x7000-0x7fff,
# 0xd000-0xdfff in blokken van 32 bytes. Sensor moet aanstaan (i2c bus 3, 0x10);
# ccs hoeft er NIET voor geladen te zijn.
set -uo pipefail
UIT=${1:?gebruik: $0 <uitvoerbestand>}
BUS=3

python3 - "$UIT" <<'EOF'
import subprocess, sys
uit = open(sys.argv[1], 'w')
BLOKKEN = [(0x0000, 0x1000), (0x3000, 0x1000), (0x7000, 0x1000), (0xd000, 0x1000)]
fouten = 0
for start, lengte in BLOKKEN:
    for adr in range(start, start + lengte, 8):
        for poging in range(3):
            r = subprocess.run(
                ['i2ctransfer', '-f', '-y', '3',
                 f'w2@0x10', f'0x{adr>>8:02x}', f'0x{adr&0xff:02x}', 'r8'],
                capture_output=True, text=True)
            if r.returncode == 0:
                waarden = r.stdout.split()
                for i, v in enumerate(waarden):
                    uit.write(f'0x{adr+i:04x} {v}\n')
                break
        else:
            fouten += 1
            uit.write(f'0x{adr:04x} LEESFOUT\n')
uit.close()
print(f'klaar: {sys.argv[1]} ({fouten} leesfouten)')
EOF
