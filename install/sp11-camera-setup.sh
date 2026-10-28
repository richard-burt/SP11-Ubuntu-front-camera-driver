#!/bin/bash
# sp11-camera-setup.sh — install the IMX681 front-camera bring-up (needs root).
# Run from the workspace:  sudo bash install/sp11-camera-setup.sh
# Idempotent. No DTB/boot change: the sensor node keeps compatible
# "sony,imx681"; the in-tree D-PHY imx681 driver is blacklisted and ccs.ko is
# bound by driver_override instead.
set -euo pipefail

KVER="$(uname -r)"
WS="/home/richard/Documents/projects/this-installed-ubuntu/front-camera"
UPD="/lib/modules/${KVER}/updates"
SHARE="/usr/local/share/sp11-camera"
FW="ccs-sensor-4260-0681-0010.fw"

say() { echo "[sp11-cam] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }
[ -f "$WS/sp11-imx681/phy/phy-qcom-mipi-csi2.ko" ] || { echo "modules not built in $WS/sp11-imx681" >&2; exit 1; }

say "kernel: ${KVER}"

# ---------------------------------------------------------------- modules ---
mkdir -p "$UPD"
cp -f "$WS/sp11-imx681/phy/phy-qcom-mipi-csi2.ko" \
      "$WS/sp11-imx681/camss/qcom-camss.ko" \
      "$WS/sp11-imx681/ccs/ccs.ko" "$UPD/"
# ensure the static-data firmware is where the ccs driver looks for it
# (ccs_firmware_name() requests "ccs/ccs-sensor-<mfr>-<model>-<rev>.fw")
mkdir -p /lib/firmware/ccs
cp -f "$WS/sp11-imx681/sensor-data/${FW}" /lib/firmware/ccs/
depmod -a
say "modules installed to ${UPD} (+ ${FW})"

# ------------------------------------------------------------ modprobe.d ---
cat > /etc/modprobe.d/sp11-camera.conf <<'EOF'
# SP11 IMX681 front camera: C-PHY reception (x1e80100 CSIPHY2/trio0) +
# CCS sensor driver with 0x0111=3 (C-PHY), LLP-8704 Windows vendor tables.
# The node keeps compatible "sony,imx681"; the in-tree D-PHY-only driver is
# blacklisted and ccs is bound to it by explicit driver_override.
blacklist imx681
options phy-qcom-mipi-csi2 force_cphy=1
options qcom_camss force_cphy=1
options ccs imx681_cphy=1
EOF
say "modprobe.d written"

# ---------------------------------------------------------------- scripts ---
mkdir -p "$SHARE"
install -m 755 "$WS/install/sp11-camera-prepare.sh" /usr/local/sbin/sp11-camera-prepare
install -m 755 "$WS/install/sp11-camera-start.sh"   /usr/local/sbin/sp11-camera-start
install -m 755 "$WS/install/sp11-camera-led.sh"     /usr/local/sbin/sp11-camera-led
install -m 644 "$WS/sp11-imx681/scripts/raw-naar-png.py" "$SHARE/raw-naar-png.py"
say "scripts installed"

# ------------------------------------------------------------------ units ---
sed "s|ExecStart=.*|ExecStart=/usr/local/sbin/sp11-camera-prepare|" \
    "$WS/sp11-imx681/userspace/systemd/sp11-camera.service" > /etc/systemd/system/sp11-camera.service
cp -f "$WS/sp11-imx681/userspace/systemd/sp11-camera-led.service" /etc/systemd/system/
mkdir -p /etc/systemd/user/pipewire.service.d
cp -f "$WS/sp11-imx681/userspace/pipewire/sp11-camera.conf" \
      /etc/systemd/user/pipewire.service.d/sp11-camera.conf
systemctl daemon-reload
systemctl enable sp11-camera.service sp11-camera-led.service 2>/dev/null || true
say "systemd units installed and enabled"

# ---------------------------------------------------------- IPA tuning -----
# The soft-IPA selects the tuning file by sensor name (ccs subdevs are named
# "smiapp ..."): install the merged factory profile under BOTH names.
install -m 644 "$WS/install/libcamera-smiapp.yaml" /usr/share/libcamera/ipa/simple/smiapp.yaml
# mirror the tuning under the sensor-family name for libcamera versions
# that select by sensor model id
cp -f /usr/share/libcamera/ipa/simple/smiapp.yaml /usr/share/libcamera/ipa/simple/imx681.yaml
say "libcamera IPA tuning installed (factory CCMs + gamma 2.8: smiapp.yaml + imx681.yaml)"

# ----------------------------------------------------- live module reload ---
say "switching live modules..."
modprobe -r ccs 2>/dev/null || true
modprobe -r imx681 2>/dev/null || true
modprobe -r qcom_camss 2>/dev/null || true
modprobe qcom_camss force_cphy=1
sleep 1
modprobe ccs imx681_cphy=1
sleep 2
/usr/local/sbin/sp11-camera-prepare && say "camera modules ready"

cat <<'EOT'

[sp11-cam] DONE. Test now (no reboot needed):
  sudo /usr/local/sbin/sp11-camera-start 3
  → /var/tmp/sp11-cam/frame-cphy.raw (3844x2640 RAW10) + frame-cphy.png
EOT