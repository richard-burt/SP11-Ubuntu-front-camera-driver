#!/bin/bash
# settle-sweep — sweep the C-PHY cphy_settle override and measure stream
# survival. For each candidate value: write cphy_settle, rebind ccs (fresh
# sensor state), then run CLEAN 800-frame captures (no mid-stream subdev
# interaction) twice; wedged runs restart via rebind. Prints per-value
# survival summary.
# NOTE: raw frame files NEVER go to /tmp — /tmp is RAM-backed tmpfs here
# (7.3 GB) and 800 frames = ~10.1 GB; the disk-backed RAWDIR is mandatory.
# Values may be passed with or without 0x prefix (cdr-sweep-style bare
# values and 0x-prefixed values both accepted).
# Run as root: sudo bash /tmp/opencode/settle-sweep.sh <val> [val...]
set -uo pipefail
RAWDIR=/var/tmp/sp11-cam
mkdir -p "$RAWDIR"
V=/sys/module/phy_qcom_mipi_csi2/parameters

rebind_ccs() {
  local DEV
  DEV=$(for d in /sys/bus/i2c/devices/*; do
    [ "$(basename "$(readlink -f "$d/driver" 2>/dev/null)")" = ccs ] && basename "$d"
  done)
  [ -n "$DEV" ] && echo "$DEV" > "/sys/bus/i2c/devices/$DEV/driver/unbind" 2>/dev/null
  modprobe -r ccs 2>/dev/null
  modprobe ccs 2>/dev/null
  sleep 2
  # auto-probe can miss after camss churn; force the bind
  # shellcheck disable=SC2010
  if ! ls /sys/bus/i2c/drivers/ccs/ 2>/dev/null | grep -q -- '-0010'; then
    local B
    # shellcheck disable=SC2010
    B=$(ls /sys/bus/i2c/devices/ | grep -- '-0010' | head -1)
    [ -n "$B" ] && echo "$B" > /sys/bus/i2c/drivers/ccs/bind 2>/dev/null
    sleep 2
  fi
}

run800() {
  local f="$RAWDIR/settle-$1-$2.raw"
  rm -f "$f"
  v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2640,pixelformat=pRAA >/dev/null 2>&1
  timeout 70 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=800 --stream-to="$f" >/dev/null 2>&1
  local sz
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  echo $(( sz / 12672000 ))
  rm -f "$f"
}

for S in "$@"; do
  # strip any number of 0x/0X prefixes, then always write 0x+value
  # (round-2 audit finding: single ${S#0x} strips are not idempotent)
  while [[ $S == 0[xX]* ]]; do S=${S:2}; done
  echo 0x"$S" > "$V/cphy_settle" 2>/dev/null || { echo "settle-sweep: cannot write cphy_settle" >&2; exit 1; }
  echo "=== cphy_settle=0x$S (readback $(cat "$V/cphy_settle")) ==="
  for i in 1 2; do
    rebind_ccs
    N=$(run800 "$S" "$i")
    echo "  run $i: $N/800 frames"
  done
done
echo "sweep done"