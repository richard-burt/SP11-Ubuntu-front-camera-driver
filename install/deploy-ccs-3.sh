#!/bin/bash
# deploy-ccs-3 — swap in ccs.ko with three fixes: (1) "imx681" entity-name
# override, (2) 16x fixed stream-on digital gain, (3) NEW: throttle mid-stream
# exposure/gain register writes to <=5/s + no-op skip (kills the AGC-induced
# CSI pipeline stall). Skips sp11-camera-prepare (stale bus path).
set -uo pipefail
say() { echo "[deploy-ccs-3] $*"; }
fail() { echo "deploy-ccs-3: FAILED: $*" >&2; exit 1; }

KREL="$(uname -r)"
UPD="/lib/modules/$KREL/updates"
SRC="/home/richard/Documents/projects/this-installed-ubuntu/front-camera/sp11-imx681/ccs/ccs.ko"
NEWSRC="54D7093D00F26301A5F587C"

[ -r "$SRC" ] || fail "source ccs.ko missing"
LIVE="$(modinfo -F srcversion "$SRC" 2>/dev/null || echo none)"
[ "$LIVE" = "$NEWSRC" ] || fail "source module srcversion=$LIVE, want $NEWSRC"
say "kernel $KREL; deploying srcversion $NEWSRC"

# 1. stop user session camera users, drain devices
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
  [ -z "$(lsof -t /dev/media0 2>/dev/null)" ] || fail "/dev/media0 still held"
  say "pipewire/wireplumber stopped+masked (media0 free)"
fi

# 2. unbind ccs-bound i2c device (bus number varies per boot)
DEV=""
for d in /sys/bus/i2c/devices/*; do
  if [ "$(basename "$(readlink -f "$d/driver" 2>/dev/null)")" = "ccs" ]; then
    DEV="$(basename "$d")"
  fi
done
[ -n "$DEV" ] || fail "no i2c device bound to ccs"
echo "$DEV" > "/sys/bus/i2c/devices/$DEV/driver/unbind" 2>/dev/null \
  || fail "cannot unbind $DEV"
say "$DEV unbound"

# 3. rmmod, install, reprobe
modprobe -r ccs 2>/dev/null || fail "rmmod ccs refused"
[ -d /sys/module/ccs ] && fail "ccs still in sysfs"
install -m 0644 "$SRC" "$UPD/ccs.ko" || fail "install failed"
depmod -a "$KREL" || fail "depmod failed"
modprobe ccs || fail "modprobe ccs failed"
sleep 2
SAYLIVE="$(cat /sys/module/ccs/srcversion 2>/dev/null || echo none)"
[ "$SAYLIVE" = "$NEWSRC" ] || fail "wrong live srcversion $SAYLIVE"
say "ccs srcversion live: $SAYLIVE"

# 4. phy receive window (runtime params, proven values)
P=/sys/module/phy_qcom_mipi_csi2/parameters
echo 0 > "$P/cphy_rate" 2>/dev/null || true
echo 0x4a > "$P/cphy_cdr" 2>/dev/null || true
say "phy rate=$(cat $P/cphy_rate) cdr=$(cat $P/cphy_cdr)"

# 5. capture sanity test (no prepare call)
sleep 2
BENT="$(media-ctl -d /dev/media0 -p 2>/dev/null | grep -c imx681 || true)"
[ "${BENT:-0}" -ge 2 ] || fail "imx681 entities missing ($BENT)"
bash /tmp/opencode/capture-noprep.sh 2 || fail "capture sanity"

# 6. restore user services
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