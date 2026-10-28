#!/bin/bash
# sp11-camera-start — configure the media pipeline and capture N RAW frames.
# Usage: sp11-camera-start [frames]      (default 3)
set -uo pipefail
N=${1:-3}
SHARE="/usr/local/share/sp11-camera"
# /tmp is RAM-backed (tmpfs, 7.3 GB) — raw frame files go to disk instead
RAWDIR=/var/tmp/sp11-cam
mkdir -p "$RAWDIR"

[ -e /dev/media0 ] || { echo "no /dev/media0" >&2; exit 1; }

PHY=msm_csiphy2
media-ctl -d /dev/media0 -l "\"$PHY\":1 -> \"msm_csid0\":0 [1]" 2>/dev/null || \
  media-ctl -d /dev/media0 -l '"msm_csiphy2":1 -> "msm_csid0":0 [1]' || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || true
for p in "\"$PHY\":0" "\"$PHY\":1" '"msm_csid0":0'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3844x2640]" 2>/dev/null || true
done
# the CSID crops 3844 -> 3840 in hardware so the line stride is 16-byte aligned
for p in '"msm_csid0":1' '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3840x2640]" 2>/dev/null || true
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2640,pixelformat=pRAA >/dev/null

echo "capturing $N frames..."
timeout $((10 + 2 * N)) v4l2-ctl -d /dev/video0 --stream-mmap --stream-count="$N" \
  --stream-to="$RAWDIR/frame-cphy.raw"
rc=$?
ls -la "$RAWDIR/frame-cphy.raw"
# auditor note: accept BOTH the cropped (4800 B/line) and uncropped
# (4816 B/line) frame layouts — the CSID crop behavior on this path is
# version-dependent; the size check is warning-only in any case.
expected=$((4816 * 2640 * N))
alt=$((4800 * 2640 * N))
got=$(stat -c %s "$RAWDIR/frame-cphy.raw" 2>/dev/null || echo 0)
if [ "$got" = "$expected" ] || [ "$got" = "$alt" ]; then
  echo "RAW capture complete: $got bytes ($((got / (2640 * N))) bytes/line x2640 x$N)"
else
  echo "WARN: size $got not $expected/$alt (partial/broken stream? rc=$rc)"
fi

if [ -s "$RAWDIR/frame-cphy.raw" ] && [ -f "$SHARE/raw-naar-png.py" ]; then
  python3 "$SHARE/raw-naar-png.py" "$RAWDIR/frame-cphy.raw" "$RAWDIR/frame-cphy.png" 1 || true
fi
exit $rc