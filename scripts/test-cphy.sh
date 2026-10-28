#!/bin/bash
# C-PHY-test, versie 2 (12 aug 2026) — met hang-bisectie.
#
# DRAAI DIT VANAF EEN VIRTUELE CONSOLE (Ctrl+Alt+F3, inloggen), niet vanuit
# GNOME: de module print bij force_cphy=1 elk registerschrijfsel met pr_emerg
# naar de console. Loopt de machine vast, dan staat het laatste register
# ONDERAAN HET SCHERM — maak daar een foto van.
#
#   pkexec ~/sp11-camera/test-cphy.sh
set -uo pipefail
cd /home/jeroen/sp11-camera
P=/var/tmp/cphy-progress
mark() { echo "$(date +%T) $*" | tee -a $P; sync; }
: > $P

dmesg -n 8   # alle kernelmeldingen naar de console

mark "A0: sanity — camss geladen? force_cphy=$(cat /sys/module/qcom_camss/parameters/force_cphy 2>/dev/null || echo geen)"
[ -e /dev/media0 ] || { mark "A0 FOUT: geen /dev/media0"; exit 1; }

mark "A1: ccs losmaken; camss én combo-PHY herladen met force_cphy=1"
for d in /sys/bus/i2c/drivers/ccs/*-0010; do
  [ -e "$d" ] && echo "$(basename $d)" > /sys/bus/i2c/drivers/ccs/unbind
done
modprobe -r qcom_camss
modprobe -r phy_qcom_mipi_csi2
sleep 1
modprobe phy_qcom_mipi_csi2 force_cphy=1
modprobe qcom_camss force_cphy=1
sleep 2
[ "$(cat /sys/module/phy_qcom_mipi_csi2/parameters/force_cphy)" = Y ] || {
  mark "A1 FOUT: phy-force_cphy niet actief"; exit 1; }
[ "$(cat /sys/module/qcom_camss/parameters/force_cphy)" = Y ] || { mark "A1 FOUT: force_cphy niet actief"; exit 1; }
[ -e /dev/media0 ] || { mark "A1 FOUT: geen /dev/media0 na herladen"; dmesg | tail -10; exit 1; }
mark "A1 OK: camss draait in C-PHY-modus (nog niets naar de PHY geschreven)"

mark "A2: ccs opnieuw binden"
DEV=$(ls /sys/bus/i2c/devices/ | grep -E '^[0-9]+-0010$' | head -1)
echo "$DEV" > /sys/bus/i2c/drivers/ccs/bind || { mark "A2 FOUT: bind faalde"; exit 1; }
sleep 2
[ -d "/sys/bus/i2c/drivers/ccs/$DEV" ] || { mark "A2 FOUT: ccs niet gebonden"; exit 1; }
mark "A2 OK: sensor gebonden"

mark "B: pijplijn en formaten instellen (raakt de hardware nog niet)"
media-ctl -d /dev/media0 -l '"msm_csiphy4":1 -> "msm_csid0":0 [1]' || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || true
for p in '"msm_csiphy4":0' '"msm_csiphy4":1' '"msm_csid0":0' '"msm_csid0":1' \
         '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3840x2160]" 2>/dev/null || true
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=pRAA || true
mark "B OK"

echo
echo ">>> NU KOMT DE SPANNENDE STAP: STREAMON schrijft de C-PHY-registers."
echo ">>> Bij een hang: foto van de laatste 'sp11cphy:'-regel op het scherm."
read -r -p ">>> Enter om door te gaan... "

mark "C: STREAMON"
timeout 10 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3 \
  --stream-to=/tmp/frame-cphy.raw &
sleep 4
mark "C: machine leeft nog — CSID lezen"
./lees-csid.sh 2>&1 | tee -a $P
wait || true
sync
mark "KLAAR. CSI2_RX_IRQ_STATUS != 0x00000000 => ontvangst!"
grep -E 'vfe0|csid0' /proc/interrupts | tee -a $P
