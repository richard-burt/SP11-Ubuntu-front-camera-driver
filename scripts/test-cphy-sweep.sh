#!/bin/bash
# Volledige C-PHY-sweep op de actieve CSIPHY (werkt op elke phy-variant).
# Detecteert zelf welke msm_csiphyN in de mediagraph zit, zet de pijplijn op,
# en meet trio 0-2 x datarate-rij 0-4. Log: /var/tmp/cphy-sweep.
#
#   pkexec ~/sp11-camera/test-cphy-sweep.sh
set -uo pipefail
cd /home/jeroen/sp11-camera
P=/var/tmp/cphy-sweep
: > $P
log() { echo "$*" | tee -a $P; sync; }

for d in /sys/bus/i2c/drivers/ccs/*-0010; do
  [ -e "$d" ] && basename "$d" > /sys/bus/i2c/drivers/ccs/unbind
done
modprobe -r qcom_camss 2>/dev/null || true
modprobe -r phy_qcom_mipi_csi2 2>/dev/null || true
sleep 1
modprobe phy_qcom_mipi_csi2 force_cphy=1
modprobe qcom_camss force_cphy=1
sleep 2
[ -e /dev/media0 ] || { log "FOUT: geen /dev/media0"; exit 1; }
# Gilerson-config met 0x0111=3 (C-PHY) i.p.v. 2 — de bewezen PLL (969,6 -> ~970
# Msym/s) blijft staan, alleen de signalling-modus wisselt.
echo 1 > /sys/module/ccs/parameters/imx681_cphy 2>/dev/null || true
DEV=$(ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-0010$' | head -1)
echo "$DEV" > /sys/bus/i2c/drivers/ccs/bind 2>/dev/null || true; sleep 2

# HARDE EIS: zonder gebonden sensor kan er geen stream lopen, en registers
# lezen zonder stream (klokken uit) hangt de bus -> harde reset (13 aug).
if ! ls /sys/bus/i2c/drivers/ccs/ | grep -q '\-0010$'; then
  log "ccs niet gebonden (bekende boot-race), herlaadpoging..."
  modprobe -r ccs 2>/dev/null; sleep 1; modprobe ccs
  echo 1 > /sys/module/ccs/parameters/imx681_cphy
  sleep 3
  ls /sys/bus/i2c/drivers/ccs/ | grep -q '\-0010$' || {
    log "AFGEBROKEN: ccs bindt niet, geen metingen (dat zou de bus hangen)."
    exit 1; }
fi
log "ccs gebonden: $(ls /sys/bus/i2c/drivers/ccs/ | grep '\-0010$')"

PHY=$(media-ctl -d /dev/media0 -p | grep -oE 'msm_csiphy[0-9]' | sort -u | head -1)
log "actieve csiphy-entiteit: $PHY (DTB: $(tr -d '\0' < /proc/device-tree/model))"

media-ctl -d /dev/media0 -l "\"$PHY\":1 -> \"msm_csid0\":0 [1]" || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || true
for p in "\"$PHY\":0" "\"$PHY\":1" '"msm_csid0":0' '"msm_csid0":1' \
         '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3844x2640]" 2>/dev/null || true
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3844,height=2640,pixelformat=pRAA >/dev/null

for T in 0 1 2; do
  echo $T > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_trio
  echo $T > /sys/module/qcom_camss/parameters/cphy_input
  for R in 0 1 2 3 4; do
    echo $R > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_rate
    OUT=$(./lees-cphy-status.sh 2>/dev/null | grep -E 'RX_IRQ_STATUS')
    log "trio=$T rate=$R :: $OUT"
  done
done
log "sweep klaar. Alles 00 = niets ontvangen op deze csiphy."
