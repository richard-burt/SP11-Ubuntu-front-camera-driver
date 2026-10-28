#!/bin/bash
# cdr-sweep — sweep the C-PHY CDR override and measure stream survival.
# For each candidate value: rebind ccs (fresh sensor state), then run
# CLEAN 400-frame captures (no mid-stream subdev interaction) three times;
# wedged runs restart via rebind. Prints per-value survival summary.
# Run as root: sudo bash /tmp/opencode/cdr-sweep.sh <val> [val...]
set -uo pipefail
# /tmp is RAM-backed (tmpfs, 7.3 GB) — raw frame files go to disk instead
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
  # sysfs device names are fixed-width hex (e.g. 1-0010) — no glob hazards
  # shellcheck disable=SC2010
  if ! ls /sys/bus/i2c/drivers/ccs/ 2>/dev/null | grep -q -- '-0010'; then
    local B
    # shellcheck disable=SC2010
    B=$(ls /sys/bus/i2c/devices/ | grep -- '-0010' | head -1)
    [ -n "$B" ] && echo "$B" > /sys/bus/i2c/drivers/ccs/bind 2>/dev/null
    sleep 2
  fi
}

run400() {
  local f="$RAWDIR/cdr-$1-$2.raw"
  rm -f "$f"
  v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2640,pixelformat=pRAA >/dev/null 2>&1
  timeout 40 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=400 --stream-to="$f" >/dev/null 2>&1
  local sz
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  echo $(( sz / 12672000 ))
  rm -f "$f"
}

for CDR in "$@"; do
  echo 0x"$CDR" > "$V/cphy_cdr" 2>/dev/null || { echo "cdr-sweep: cannot write cphy_cdr" >&2; exit 1; }
  echo "=== cphy_cdr=0x$CDR ==="
  for i in 1 2 3; do
    rebind_ccs
    N=$(run400 "$CDR" "$i")
    echo "  run $i: $N/400 frames"
  done
done
echo "sweep done"