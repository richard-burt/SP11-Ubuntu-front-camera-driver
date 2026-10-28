#!/bin/bash
# sp11-camera-full-reload — recover the front camera stack after a wedged
# stream: stop user services, unload ccs+camss+phy, reload with the proven
# parameters, rebind, rebuild the media pipeline, sanity capture.
# Bus-path agnostic (the ccs-bound i2c device is discovered, not hardcoded).
set -uo pipefail
say() { echo "[full-reload] $*"; }
fail() { echo "full-reload: FAILED: $*" >&2; exit 1; }

# 1. stop user session camera users (mask first: socket activation)
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
  for _ in 1 2 3 4 5; do
    [ -z "$(lsof -t /dev/media0 2>/dev/null)" ] && break
    sleep 1
  done
  say "user services down (media0 free: $(lsof -t /dev/media0 | wc -l) holders)"
fi

# 2. full module reload: ccs → camss → phy, in reverse load order
DEV=$(for d in /sys/bus/i2c/devices/*; do
  [ "$(basename "$(readlink -f "$d/driver" 2>/dev/null)")" = ccs ] && basename "$d"
done)
[ -n "$DEV" ] && { echo "$DEV" > "/sys/bus/i2c/devices/$DEV/driver/unbind"; say "$DEV unbound"; }
for m in ccs ccs_pll v4l2_cci qcom_camss phy_qcom_mipi_csi2; do
  modprobe -r "$m" 2>/dev/null
done
sleep 1
modprobe phy_qcom_mipi_csi2 force_cphy=1 || fail "modprobe phy"
modprobe qcom_camss force_cphy=1 || fail "modprobe camss"
modprobe ccs || fail "modprobe ccs"
sleep 2
# auto-probe of the i2c client can miss after camss churn: force the bind
BOUND=no
for d in /sys/bus/i2c/devices/*; do
  [ "$(basename "$(readlink -f "$d/driver" 2>/dev/null)")" = ccs ] && BOUND=yes
done
if [ "$BOUND" = no ]; then
  B=""
  for d in /sys/bus/i2c/devices/*-0010; do
    B="$(basename "$d")"
    break
  done
  [ -n "$B" ] && { echo "$B" > /sys/bus/i2c/drivers/ccs/bind; sleep 2; }
  say "forced bind of $B"
  [ "$(basename "$(readlink -f "/sys/bus/i2c/devices/$B/driver" 2>/dev/null)")" = ccs ] \
    || fail "ccs did not bind to $B"
fi
say "camss=$(cat /sys/module/qcom_camss/srcversion) ccs=$(cat /sys/module/ccs/srcversion)"

# 3. phy receive window
P=/sys/module/phy_qcom_mipi_csi2/parameters
echo 0 > "$P/cphy_rate" 2>/dev/null || true
echo 0x4a > "$P/cphy_cdr" 2>/dev/null || true
say "phy rate=$(cat "$P/cphy_rate") cdr=$(cat "$P/cphy_cdr")"

# 4. capture sanity
bash /tmp/opencode/capture-noprep.sh 2 || fail "capture sanity"

# 5. user services back
if [ -d /run/user/1000 ]; then
  sudo -u richard env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    systemctl --user unmask pipewire.service pipewire.socket \
    pipewire-pulse.service pipewire-pulse.socket wireplumber.service || true
  sudo -u richard env XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
  say "user services restored"
fi
say "done"