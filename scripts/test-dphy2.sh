#!/bin/bash
# D-PHY 2-lane-test op CSIPHY2 (djmulder/linux-surface #2153: de IMX681 is
# D-PHY, niet C-PHY; onze 0x0111=3 kwam uit onze eigen inittabel).
# Draaien na een boot met sp11-denali-dphy2.dtb. Alles stock: geen force_cphy.
#
#   pkexec ~/sp11-camera/test-dphy2.sh
set -uo pipefail
cd /home/jeroen/sp11-camera
P=/var/tmp/dphy2-test
: > $P
log() { echo "$*" | tee -a $P; sync; }

modprobe qcom_camss 2>/dev/null || true
sleep 1
[ -e /dev/media0 ] || { log "FOUT: geen /dev/media0"; exit 1; }
[ "$(cat /sys/module/phy_qcom_mipi_csi2/parameters/force_cphy)" = N ] || {
  log "FOUT: force_cphy staat aan"; exit 1; }
DEV=$(ls /sys/bus/i2c/drivers/ccs/ 2>/dev/null | grep -E '^[0-9]+-0010$' | head -1)
[ -n "$DEV" ] || { log "FOUT: ccs niet gebonden"; dmesg | grep -i ccs | tail -5; exit 1; }
log "sensor: $DEV; DTB: $(tr -d '\0' < /proc/device-tree/model)"

PHY=$(media-ctl -d /dev/media0 -p | grep -oE 'msm_csiphy[0-9]' | sort -u | head -1)
log "actieve csiphy: $PHY (bepaald door de gekozen DTB-variant)"

media-ctl -d /dev/media0 -l "\"$PHY\":1 -> \"msm_csid0\":0 [1]" || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || true
# Gilerson-modus: 3844x2640 (H-flip in de sensor maakt de echte Bayer GRBG,
# maar ccs meldt SRGGB10 — voor "is er ontvangst?" irrelevant).
for p in "\"$PHY\":0" "\"$PHY\":1" '"msm_csid0":0' '"msm_csid0":1' \
         '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3844x2640]" 2>/dev/null || true
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3844,height=2640,pixelformat=pRAA >/dev/null

log "controle sensor-signalling tijdens stream (moet 0x02 = D-PHY zijn):"
BUS=${DEV%%-*}
timeout 16 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3 \
  --stream-to=/tmp/frame-dphy.raw 2>&1 | tee -a $P &
sleep 4
echo -n "  0x0111 = " | tee -a $P
i2ctransfer -f -y $BUS w2@0x10 0x01 0x11 r1 | tee -a $P
echo -n "  PLL 0x0307/0x030d-0f (verwacht e1 / 03 01 2f = 969,6 MHz) = " | tee -a $P
i2ctransfer -f -y $BUS w2@0x10 0x03 0x07 r1 | tr -d "\n" | tee -a $P
echo -n " / " | tee -a $P
i2ctransfer -f -y $BUS w2@0x10 0x03 0x0d r3 | tee -a $P
echo -n "  framecounter 0x0005 (2x, moet oplopen): " | tee -a $P
i2ctransfer -f -y $BUS w2@0x10 0x00 0x05 r1 | tr -d "\n" | tee -a $P; sleep 1
echo -n " -> " | tee -a $P
i2ctransfer -f -y $BUS w2@0x10 0x00 0x05 r1 | tee -a $P
./lees-csid.sh 2>&1 | tee -a $P
wait || true
sync
log "--- interrupts:"
grep -E 'vfe0|csid0' /proc/interrupts | tee -a $P
ls -la /tmp/frame-dphy.raw 2>/dev/null | tee -a $P
log "KLAAR. RX_IRQ_STATUS != 0 en/of een gevulde frame-dphy.raw = feest."
