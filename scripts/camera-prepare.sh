#!/bin/bash
# SP11-voorcamera: modules in de juiste staat brengen (boot + handmatig).
# Wordt gedraaid door sp11-camera.service en door camera-start.sh.
# - phy_qcom_mipi_csi2 laadt bij boot uit de initramfs; als de modprobe.d-
#   opties (force_cphy enz.) daarbij gemist zijn: herladen.
# - ccs heeft een bekende boot-race ("no valid link frequencies"): herladen.
set -uo pipefail

modprobe phy_qcom_mipi_csi2
if [ "$(cat /sys/module/phy_qcom_mipi_csi2/parameters/force_cphy)" != "Y" ]; then
  echo "PHY-module zonder C-PHY-parameters geladen; herladen..."
  modprobe -r qcom_camss 2>/dev/null || true
  modprobe -r ccs 2>/dev/null || true
  modprobe -r phy_qcom_mipi_csi2
  modprobe phy_qcom_mipi_csi2
  grep -q Y /sys/module/phy_qcom_mipi_csi2/parameters/force_cphy || {
    echo "FOUT: force_cphy blijft N"; exit 1; }
fi

modprobe qcom_camss
modprobe ccs
sleep 2

# Wapening (13 aug 2026): na een reboot bleek er één keer een verouderde
# qcom_camss in het geheugen te zitten (srcversion week af van updates/)
# → crop uit → husselstroken. Vergelijk expliciet en herlaad zonodig.
for MOD in qcom_camss ccs; do
  BESTAND=/lib/modules/$(uname -r)/updates/$(echo $MOD | tr _ -).ko
  [ -f "$BESTAND" ] || continue
  WIL=$(modinfo -F srcversion "$BESTAND")
  IS=$(cat /sys/module/$MOD/srcversion 2>/dev/null || echo geen)
  if [ "$WIL" != "$IS" ]; then
    echo "$MOD: verkeerde versie geladen ($IS, wil $WIL); herladen..."
    depmod -a
    modprobe -r ccs 2>/dev/null || true
    modprobe -r qcom_camss 2>/dev/null || true
    modprobe qcom_camss
    modprobe ccs
    sleep 2
    break
  fi
done
if ! ls /sys/bus/i2c/drivers/ccs/ 2>/dev/null | grep -q -- '-0010$'; then
  modprobe -r ccs; sleep 1; modprobe ccs; sleep 3
fi
ls /sys/bus/i2c/drivers/ccs/ | grep -q -- '-0010$' || {
  echo "FOUT: ccs bindt niet"; exit 1; }
echo "camera-modules klaar"
