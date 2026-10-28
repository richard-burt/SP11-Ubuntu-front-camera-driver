#!/bin/bash
# Verdieping op lees-cphy-status.sh: pakkettellers + header-capture van CSID0.
# UNMAPPED_VC_DT vuurt (13 aug) -> er arriveren parseerbare pakketheaders; dit
# script vangt er een en toont VC/DT. Alleen draaien terwijl een stream kan
# starten (zelfde guard als lees-cphy-status.sh).
set -uo pipefail

timeout 20 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 >/dev/null 2>&1 &
STREAM=$!
sleep 2
if ! kill -0 $STREAM 2>/dev/null; then
  echo "GEEN LOPENDE STREAM — registers niet gelezen."
  exit 1
fi

python3 - <<'EOF'
import mmap, os, struct, time

CSID = 0xacb7000
fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, 0x2000, mmap.MAP_SHARED,
               mmap.PROT_READ | mmap.PROT_WRITE, offset=CSID)

def rd(off): return struct.unpack('<I', mm[off:off+4])[0]
def wr(off, v): mm[off:off+4] = struct.pack('<I', v)

# IRQ-status schonen zodat we vers latchen (write-1-to-clear + cmd-strobe 0x80)
wr(0xa4, 0xffffffff)
wr(0x80, 1)
# capture aan: long/short/cphy-pkt (EN-bits 0..2), VC/DT-match op 0/alles
wr(0x208, 0x7)
time.sleep(2.5)

print(f'CSI2_RX_IRQ_STATUS   = 0x{rd(0x9c):08x}  (vers gelatcht)')
print(f'TOTAL_PKTS_RCVD      = {rd(0x240)}')
print(f'STATS_ECC            = {rd(0x244)}')
print(f'CRC_ERRORS           = {rd(0x248)}')
l0, l1 = rd(0x20c), rd(0x210)
s0, s1 = rd(0x214), rd(0x218)
ch = rd(0x21c)
print(f'CAPTURED_LONG_PKT_0/1  = 0x{l0:08x} 0x{l1:08x}')
print(f'CAPTURED_SHORT_PKT_0/1 = 0x{s0:08x} 0x{s1:08x}')
print(f'CAPTURED_CPHY_PKT_HDR  = 0x{ch:08x}')
if l0:
    # long pkt hdr: [5:0]+[15:10]? klassiek: DT=[5:0], VC=[23:22]+, WC=[21:6]
    print(f'  long: DT=0x{l0 & 0x3f:02x} WC={(l0 >> 6) & 0xffff} '
          f'VC={(l0 >> 22) & 0x1f}')
if ch:
    print(f'  cphy-hdr ruw: DT=0x{ch & 0x3f:02x} rest=0x{ch >> 6:x}')
mm.close(); os.close(fd)
EOF

wait $STREAM 2>/dev/null || true
