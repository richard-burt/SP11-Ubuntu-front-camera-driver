#!/usr/bin/env python3
"""RAW10-packed dump van de SP11-voorcamera omzetten naar PNG (halve resolutie).

Puur stdlib (zlib): geen numpy/PIL nodig.
Gebruik: raw-naar-png.py <in.raw> <uit.png> [frame-index]
Dumpstructuur (sinds LLP 8704, 13 aug 2026): records van 4816 bytes per
sensorregel (4805 bytes payload = 3844 px RAW10, rest pad), 2640 regels,
frame = sizeimage = 4816*2640. Bayer GRBG (H-flip). Frame-index werkt
rechtstreeks op /tmp/frame-cphy.raw.
"""
import struct, sys, zlib

W, H, STRIDE = 3840, 2640, 4800
FRAME = STRIDE * H

src, dst = sys.argv[1], sys.argv[2]
idx = int(sys.argv[3]) if len(sys.argv) > 3 else 0
data = open(src, 'rb').read()[idx * FRAME:(idx + 1) * FRAME]
assert len(data) == FRAME, f'frame {idx} niet compleet'

# Per rij alleen de 4 hoge bytes van elke 5-bytegroep (8-bit benadering);
# payload is 4805 bytes, de rest van het record is pad.
def rij(r):
    b = data[r * STRIDE:(r + 1) * STRIDE]
    return bytes(v for i, v in enumerate(b) if i % 5 != 4)

# Halve resolutie: per 2x2-Bayerblok (GRBG) één RGB-pixel.
OW, OH = W // 2, H // 2
histo = [0] * 256
rgb_rijen = []
for y in range(OH):
    r0, r1 = rij(2 * y), rij(2 * y + 1)
    uit = bytearray(OW * 3)
    for x in range(OW):
        g1 = r0[2 * x]; rr = r0[2 * x + 1]
        bb = r1[2 * x]; g2 = r1[2 * x + 1]
        g = (g1 + g2) >> 1
        uit[3 * x] = rr; uit[3 * x + 1] = g; uit[3 * x + 2] = bb
        histo[g] += 1
    rgb_rijen.append(bytes(uit))

# Autostretch op de groene histogram: 1e-99e percentiel.
tot = OW * OH
c = 0; lo = 0
for i, n in enumerate(histo):
    c += n
    if c >= tot * 0.01: lo = i; break
c = 0; hi = 255
for i in range(255, -1, -1):
    c += histo[i]
    if c >= tot * 0.01: hi = i; break
span = max(hi - lo, 1)
# gamma 0.45 zodat donkere binnenscenes zichtbaar blijven
lut = bytes(min(255, max(0, round(255 * (max(0, min(1, (v - lo) / span)) ** 0.45))))
            for v in range(256))
print(f'stretch: zwart={lo} wit={hi} (gamma 0.45)')

raw = b''.join(b'\x00' + bytes(lut[v] for v in r) for r in rgb_rijen)

def chunk(tag, payload):
    return (struct.pack('>I', len(payload)) + tag + payload +
            struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff))

png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('>IIBBBBB', OW, OH, 8, 2, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(raw, 6)) +
       chunk(b'IEND', b''))
open(dst, 'wb').write(png)
print(f'geschreven: {dst} ({OW}x{OH})')
