#!/bin/bash
# SP11-voorcamera opzetten en een testopname maken. Werkend recept 13 aug 2026:
# C-PHY op csiphy2/trio0, 1p0Gsps-AFE, CDR 0x4a, Gilerson-sensorconfig met
# 0x0111=3, LLP 8704 (line-blanking tegen FIFO-overloop!) en 3844x2640.
# Vereist de cphy-phy2-DTB in de UKI en de drie gepatchte modules
# (ccs, qcom-camss, phy_qcom_mipi_csi2) in updates/.
#
# Voor webcamgebruik is dit script NIET nodig: sp11-camera.service laadt de
# modules bij boot en libcamera/PipeWire regelen de rest ("Built-in Front
# Camera" in elke PipeWire-app).
#
#   pkexec ~/sp11-camera/camera-start.sh [aantal-frames]
set -uo pipefail
N=${1:-3}

/home/jeroen/sp11-camera/camera-prepare.sh || exit 1
[ -e /dev/media0 ] || { echo "FOUT: geen /dev/media0"; exit 1; }

PHY=$(media-ctl -d /dev/media0 -p | grep -oE 'msm_csiphy[0-9]' | sort -u | head -1)
media-ctl -d /dev/media0 -l "\"$PHY\":1 -> \"msm_csid0\":0 [1]" 2>/dev/null || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' 2>/dev/null || true
for p in "\"$PHY\":0" "\"$PHY\":1" '"msm_csid0":0'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3844x2640]" 2>/dev/null || true
done
# de csid croppt in hardware naar 3840; vanaf zijn src-pad is alles 3840
for p in '"msm_csid0":1' '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3840x2640]" 2>/dev/null || true
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2640,pixelformat=pRAA >/dev/null

echo "opname van $N frames..."
timeout $((10 + 2*N)) v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=$N \
  --stream-to=/tmp/frame-cphy.raw
ls -la /tmp/frame-cphy.raw
echo "klaar: RAW10-packed (SRGGB10P, RGGB), records van 4816 bytes, 2640 regels."
echo "renderen: python3 ~/sp11-camera/raw-naar-png.py /tmp/frame-cphy.raw uit.png 1"
