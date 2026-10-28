#!/bin/bash
# sp11-camera-fix — put the live module stack into the intended state and
# run a 3-frame capture test. Run as root:
#   sudo bash install/sp11-camera-fix.sh
set -uo pipefail
DEV=/sys/bus/i2c/devices/1-0010
say() { echo "[sp11-cam] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }
fail() { echo "sp11-camera-fix: $*" >&2; exit 1; }

say "state before:"
say "  qcom_camss srcversion: $(cat /sys/module/qcom_camss/srcversion 2>/dev/null || echo none)"
say "  force_cphy: $(cat /sys/module/qcom_camss/parameters/force_cphy 2>/dev/null || echo ABSENT-STALE-MODULE)"
if [ -e "$DEV/driver" ]; then
  say "  1-0010 bound to: $(readlink -f "$DEV/driver")"
else
  say "  1-0010: unbound"
fi

# 1. stop the user services that hold /dev/media0, /dev/video*, v4l-subdev*
#    open (pipewire/wireplumber pin qcom_camss and defeat the reload).
#    Plain "stop" is defeated by socket activation — mask first, kill,
#    then verify the drain; unmask+start at the end.
if [ -d /run/user/1000 ]; then
  sudo -u richard env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    systemctl --user mask pipewire.service pipewire.socket \
    pipewire-pulse.service pipewire-pulse.socket wireplumber.service 2>/dev/null || true
  sleep 1
  pkill -KILL -u richard -x pipewire 2>/dev/null || true
  pkill -KILL -u richard -x pipewire-pulse 2>/dev/null || true
  pkill -KILL -u richard -x wireplumber 2>/dev/null || true
  sleep 1
  # wait briefly for the device refs to drain; hard-fail if they persist
  for _ in 1 2 3 4 5; do
    [ -z "$(lsof -t /dev/media0 2>/dev/null)" ] && break
    sleep 1
  done
  if [ -n "$(lsof -t /dev/media0 2>/dev/null)" ]; then
    lsof /dev/media0 2>/dev/null
    fail "/dev/media0 still held — cannot swap modules safely"
  fi
  say "pipewire/wireplumber stopped+masked (media0 free)"
fi

# 1b. unbind whatever claims the sensor
if [ -e "$DEV/driver" ]; then
  echo "1-0010" > "$DEV/driver/unbind" && say "1-0010 unbound"
fi

# 2. full module teardown (order matters: sensor driver before camss)
if modprobe -r ccs 2>/dev/null; then
  say "ccs removed"
else
  say "ccs was not loaded"
fi
if modprobe -r imx681 2>/dev/null; then
  say "imx681 removed"
else
  say "imx681 not removable (device bound?)"
fi
if modprobe -r qcom_camss 2>/dev/null; then
  say "qcom_camss removed"
else
  say "qcom_camss busy; retrying after 2s"
  sleep 2
  modprobe -r qcom_camss
fi
if modprobe -r phy_qcom_mipi_csi2 2>/dev/null; then
  say "phy_qcom_mipi_csi2 removed (updates/ build will load)"
else
  say "phy module busy or absent; continuing"
fi

# 3. load with the C-PHY parameters
modprobe phy_qcom_mipi_csi2 force_cphy=1 || { echo "FAILED: modprobe phy_qcom_mipi_csi2" >&2; exit 1; }
# proven receive window: 1.0 Gsps AFE row (index 0), CDR 0x4a — set at
# runtime (0644) so the phy layer stops in the sync window on the first try
PDIR=/sys/module/phy_qcom_mipi_csi2/parameters
[ -d "$PDIR" ] || { echo "FAILED: no $PDIR (in-tree phy still loaded?)" >&2; exit 1; }
echo 0     > "$PDIR/cphy_rate" 2>/dev/null || true
echo 0x4a  > "$PDIR/cphy_cdr"   2>/dev/null || true
say "phy runtime params: rate=$(cat $PDIR/cphy_rate) cdr=$(cat $PDIR/cphy_cdr) trio=$(cat $PDIR/cphy_trio)"
modprobe qcom_camss force_cphy=1 || { echo "FAILED: modprobe qcom_camss force_cphy=1" >&2; exit 1; }
sleep 1
cphy="$(cat /sys/module/qcom_camss/parameters/force_cphy 2>/dev/null || echo ABSENT)"
case "$cphy" in
  1|Y) say "force_cphy now: $cphy" ;;
  *)   echo "FAILED: loaded qcom_camss has force_cphy=$cphy (stale module still in memory)" >&2; exit 1 ;;
esac
modprobe ccs imx681_cphy=1 || { echo "FAILED: modprobe ccs" >&2; exit 1; }
sleep 2
say "qcom_camss srcversion now: $(cat /sys/module/qcom_camss/srcversion 2>/dev/null || echo none)"

# 4. bind ccs and verify
/usr/local/sbin/sp11-camera-prepare || { echo "prepare failed" >&2; exit 1; }

# 5. capture test
/usr/local/sbin/sp11-camera-start 3

# 6. restart the user audio/video services (unmask first)
if [ -d /run/user/1000 ]; then
  RU=(sudo -u richard env XDG_RUNTIME_DIR=/run/user/1000 \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
  "${RU[@]}" systemctl --user unmask pipewire.service pipewire.socket \
      pipewire-pulse.service pipewire-pulse.socket wireplumber.service 2>/dev/null || true
  "${RU[@]}" systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
  say "pipewire/wireplumber unmasked+restarted"
fi
say "done"