#!/bin/bash
# CDR-fijnafregeling op trio0/rate0 (1p0Gsps) met de Gilerson-C-PHY-config.
# Per CDR-waarde: nieuwe stream, IRQ-status vers latchen, pakketteller lezen.
# Doel: SOT/PH_CRC-foutbits (12/13) weg en LONG_PKT (bit8) erbij.
#   pkexec ~/sp11-camera/test-cdr-sweep.sh
set -uo pipefail
cd /home/jeroen/sp11-camera
P=/var/tmp/cdr-sweep
: > $P
log() { echo "$*" | tee -a $P; sync; }

echo 0 > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_trio
echo 0 > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_rate
echo 0 > /sys/module/qcom_camss/parameters/cphy_input

for CDR in 0x00 0x46 0x4a 0x4e 0x52 0x54 0x56 0x58 0x5a 0x5e 0x62 0x66 0x6a; do
  echo $(( CDR )) > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_cdr
  timeout 12 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 >/dev/null 2>&1 &
  SPID=$!
  sleep 2
  if ! kill -0 $SPID 2>/dev/null; then log "cdr=$CDR :: STREAM FAALDE"; continue; fi
  OUT=$(python3 - <<'EOF'
import mmap, os, struct, time
fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, 0x2000, mmap.MAP_SHARED,
               mmap.PROT_READ | mmap.PROT_WRITE, offset=0xacb7000)
def rd(o): return struct.unpack('<I', mm[o:o+4])[0]
def wr(o, v): mm[o:o+4] = struct.pack('<I', v)
wr(0xa4, 0xffffffff); wr(0x80, 1)      # RX-IRQ clear + cmd-strobe
p0 = rd(0x240)
time.sleep(2.0)
irq = rd(0x9c); p1 = rd(0x240)
print(f'IRQ=0x{irq:08x} pkts/2s={p1 - p0}')
mm.close(); os.close(fd)
EOF
)
  log "cdr=$CDR :: $OUT"
  wait $SPID 2>/dev/null || true
done
echo 0 > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_cdr
log "klaar. gezocht: IRQ zonder 0x3000-fouten, met 0x100 (LONG_PKT)."
