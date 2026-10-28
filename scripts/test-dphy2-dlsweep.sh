#!/bin/bash
# CSID DL-invoerpermutaties opnieuw vegen, nu met de bewezen Gilerson-
# zenderconfig (969,6 MHz, 2-lane D-PHY). Eerdere sweep draaide met de
# oude vendortabel + 998,4-mismatch en was dus niet bewijskrachtig.
# Vereist: pijplijn al opgezet (test-dphy2.sh eenmaal gedraaid).
#
#   pkexec ~/sp11-camera/test-dphy2-dlsweep.sh
set -uo pipefail
cd /home/jeroen/sp11-camera
P=/var/tmp/dphy2-dlsweep
: > $P
log() { echo "$*" | tee -a $P; sync; }

[ -e /dev/media0 ] || { log "FOUT: geen /dev/media0"; exit 1; }
log "DL-sweep, DTB: $(tr -d '\0' < /proc/device-tree/model)"

# nibble per DL: dl_map = DL0 | DL1<<4; twee actieve lanes -> 12 permutaties
for A in 0 1 2 3; do
  for B in 0 1 2 3; do
    [ "$A" = "$B" ] && continue
    MAP=$(( A | (B << 4) ))
    echo $MAP > /sys/module/qcom_camss/parameters/dl_map
    timeout 10 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=2 \
      >/dev/null 2>&1 &
    SPID=$!
    sleep 3
    OUT=$(./lees-csid.sh 2>/dev/null | grep -m1 CSI2_RX_IRQ_STATUS)
    log "dl_map=0x$(printf %02x $MAP) (DL0<-lane$A DL1<-lane$B) :: $OUT"
    wait $SPID 2>/dev/null || true
  done
done
echo 0 > /sys/module/qcom_camss/parameters/dl_map
log "sweep klaar; alles 0x00000000 = niets ontvangen."
