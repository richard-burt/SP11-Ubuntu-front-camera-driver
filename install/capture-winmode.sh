#!/bin/bash
# capture-winmode — like capture-noprep but for the ccs driver's
# imx681_windows=1 register set (Windows factory mode, 3840x2160).
# Usage: capture-winmode.sh [frames]
set -uo pipefail
N=${1:-3}

# /tmp is RAM-backed (tmpfs, 7.3 GB) — raw frame files go to disk instead
RAWDIR=/var/tmp/sp11-cam
mkdir -p "$RAWDIR"

[ -e /dev/media0 ] || { echo "no /dev/media0" >&2; exit 1; }

media-ctl -d /dev/media0 -l '"msm_csiphy2":1 -> "msm_csid0":0 [1]' 2>/dev/null || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || true
media-ctl -d /dev/media0 -V '"imx681 pixel_array 3-0010":0 [fmt:SRGGB10_1X10/3840x2160]' 2>/dev/null || true
media-ctl -d /dev/media0 -V '"imx681 binner 3-0010":0 [fmt:SRGGB10_1X10/3840x2160]' 2>/dev/null || true
media-ctl -d /dev/media0 -V '"imx681 binner 3-0010":1 [fmt:SRGGB10_1X10/3840x2160]' 2>/dev/null || true
media-ctl -d /dev/media0 -V '"imx681 scaler 3-0010":0 [fmt:SRGGB10_1X10/3840x2160]' 2>/dev/null || true
media-ctl -d /dev/media0 -V '"imx681 scaler 3-0010":1 [fmt:SRGGB10_1X10/3840x2160]' || true
for p in '"msm_csiphy2":0' '"msm_csiphy2":1' '"msm_csid0":0' '"msm_csid0":1' \
         '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3840x2160]" || true
done
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2160,pixelformat=pRAA >/dev/null

echo "capturing $N frames (windows mode)..."
timeout $((10 + 2 * N)) v4l2-ctl -d /dev/video0 --stream-mmap --stream-count="$N" \
  --stream-to="$RAWDIR/frame-win.raw"
ls -la "$RAWDIR/frame-win.raw"