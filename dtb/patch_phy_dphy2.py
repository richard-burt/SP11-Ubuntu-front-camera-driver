#!/usr/bin/env python3
"""Verplaats de D-PHY-2-lane-voorcamera (Gilerson-config) naar een andere CSIPHY.

Achtergrond (13 aug 2026): met de bewezen Gilerson-zenderconfig (969,6 MHz,
2-lane D-PHY, framecounter loopt) blijft RX op csiphy2 nul. Alle eerdere
csiphy-sweeps draaiden met de oude vendortabel en zijn dus niet bewijskrachtig.
Deze variantbouwer neemt de dphy2-DTB als basis (csiphy2, camss port@2) en
verhuist camera + endpoint naar csiphy0/1/4.

Gebruik: patch_phy_dphy2.py <dphy2.dts> <uit.dts> <0|1|3>
  (3 = csiphy4/acec000; mapping camss port@N -> csiphy, zie camss.c)
"""
import re
import sys

src, dst, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
ADDR = {0: 'ace4000', 1: 'ace6000', 3: 'acec000'}[port]
dts = open(src).read()


def eis(v, t):
    if not v:
        raise SystemExit('AFGEBROKEN: ' + t)


# 1. ace8000 (csiphy2, de dphy2-basis) weer uit
m = re.search(r'csiphy@ace8000 \{.*?status = "(okay)";', dts, re.S)
eis(m, 'csiphy@ace8000 niet op okay (is dit wel de dphy2-dts?)')
dts = dts[:m.start(1)] + 'disabled' + dts[m.end(1):]

# 2. doel-csiphy aan (geen phy-type: D-PHY is de default; ace8000 draaide
#    ook zonder vdda-supplies, dus die laten we hier eveneens weg)
m = re.search(r'csiphy@%s \{.*?status = "(disabled)";' % ADDR, dts, re.S)
eis(m, 'csiphy@%s niet gevonden' % ADDR)
dts = dts[:m.start(1)] + 'okay' + dts[m.end(1):]

# 3. het camss-endpoint van port@2 naar port@<port> verhuizen
ep = re.search(r'(\n\t+endpoint@4 \{(?:[^{}]|\{[^{}]*\})*?\n\t+\};\n)', dts)
eis(ep, 'camss endpoint@4 niet gevonden')
blok = ep.group(1)
dts = dts.replace(blok, '\n', 1)
m = re.search(
    r'isp@acb6000 \{.*?port@%d \{\n(\t+)reg = <0x0%d>;'
    r'\n\t+#address-cells = <0x01>;\n\t+#size-cells = <0x00>;\n'
    % (port, port), dts, re.S)
eis(m, 'port@%d van de isp niet gevonden' % port)
dts = dts[:m.end()] + blok.rstrip('\n') + '\n' + dts[m.end():]

open(dst, 'w').write(dts)
print(f'geschreven: {dst} (camss port@{port} = csiphy@{ADDR})')
