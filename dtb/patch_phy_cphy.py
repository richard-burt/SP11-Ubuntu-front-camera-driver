#!/usr/bin/env python3
"""Verplaats de voorcamera naar een andere CSIPHY.

Achtergrond (12 aug 2026): de sensor streamt intern aantoonbaar (frame_count
telt op met ~61/s) maar CSI2_RX_IRQ_STATUS van csid0 blijft nul op alle vier de
fysieke lanes van CSIPHY4. De aanname dat de voorcamera aan CSIPHY4 hangt komt
van de Qualcomm-CRD, niet van dit board; de csiphy-toewijzing staat in ACPI en
die kunnen we niet lezen. Dus: de andere drie PHY's proberen.

Mapping (camss.c, csiphy_res_x1e80100): poort 0 = csiphy0 = ace4000,
poort 1 = csiphy1 = ace6000, poort 2 = csiphy2 = ace8000, poort 3 = csiphy4 =
acec000. Alle vier zijn 'qcom,x1e80100-mipi-csi2-combo-phy', dus dezelfde
vdda-supplies en phy-type gelden.

Gebruik: patch_phy.py <cam10.dts> <uit.dts> <0|1|2>
"""
import re
import sys

src, dst, phy = sys.argv[1], sys.argv[2], int(sys.argv[3])
ADDR = {0: 'ace4000', 1: 'ace6000', 2: 'ace8000'}[phy]
dts = open(src).read()


def eis(v, t):
    if not v:
        raise SystemExit('AFGEBROKEN: ' + t)


# 1. acec000 weer uit (props laten staan is onschadelijk bij disabled)
m = re.search(r'csiphy@acec000 \{.*?status = "(okay)";', dts, re.S)
eis(m, 'csiphy@acec000 niet op okay')
dts = dts[:m.start(1)] + 'disabled' + dts[m.end(1):]

# 2. doel-csiphy aan, met dezelfde supplies en phy-type
m = re.search(r'csiphy@%s \{.*?status = "(disabled)";' % ADDR, dts, re.S)
eis(m, 'csiphy@%s niet gevonden' % ADDR)
dts = dts[:m.start(1)] + 'okay' + dts[m.end(1):]
m = re.search(r'csiphy@%s \{.*?status = "okay";' % ADDR, dts, re.S)
extra = ('\n\t\t\tvdda-0p8-supply = <0x2a6>;'
         '\n\t\t\tvdda-1p2-supply = <0x2a5>;'
         '\n\t\t\tphy-type = <0x0b>;')
dts = dts[:m.end()] + extra + dts[m.end():]

# 3. het camss-endpoint van port@3 naar port@<phy> verhuizen
ep = re.search(
    r'(\n\t{5}endpoint@4 \{(?:[^{}]|\{[^{}]*\})*?\n\t{5}\};\n)', dts)
eis(ep, 'camss endpoint@4 niet gevonden')
blok = ep.group(1)
dts = dts.replace(blok, '\n', 1)
m = re.search(
    r'isp@acb6000 \{.*?port@%d \{\n\t{5}reg = <0x0%d>;'
    r'\n\t{5}#address-cells = <0x01>;\n\t{5}#size-cells = <0x00>;\n'
    % (phy, phy), dts, re.S)
eis(m, 'port@%d van de isp niet gevonden' % phy)
dts = dts[:m.end()] + blok.rstrip('\n') + '\n' + dts[m.end():]

open(dst, 'w').write(dts)
print(f'geschreven: {dst} (csiphy{phy} = {ADDR}, camss port@{phy})')
