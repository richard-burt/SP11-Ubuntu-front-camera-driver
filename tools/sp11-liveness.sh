#!/bin/bash
# sp11-liveness — reliable stream-liveness capture with CSID cross-check.
# Usage: sp11-liveness.sh [frames] [extra python args -> quoted]
# Sets the proven media pipeline, runs sp11-liveness.py (per-frame DQBUF
# ground truth), then prints the matching "sp11 csid stop" TOTAL_PKTS
# record so real delivered frames can be cross-checked against the log.
# All scratch goes to /var/tmp/sp11-cam — NEVER /tmp (tmpfs, 7.3 GB RAM).
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
N=${1:-800}
shift 2>/dev/null || true
RAWDIR=/var/tmp/sp11-cam
mkdir -p "$RAWDIR"

[ -e /dev/media0 ] || { echo "no /dev/media0" >&2; exit 1; }
[ -e "$HERE/sp11-liveness.py" ] || {
  echo "missing $HERE/sp11-liveness.py" >&2; exit 1
}
if [ "${N:-800}" -gt 1200 ]; then
  echo "WARN: >1200 frames = >15 GB raw on disk" >&2
fi

# --- media pipeline (identical to capture-noprep.sh) ----------------------
media-ctl -d /dev/media0 -l '"msm_csiphy2":1 -> "msm_csid0":0 [1]' 2>/dev/null || true
media-ctl -d /dev/media0 -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0 [1]' || true
for p in '"msm_csiphy2":0' '"msm_csiphy2":1' '"msm_csid0":0'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3844x2640]" 2>/dev/null || true
done
# CSID crops 3844 -> 3840 in hardware (line stride either 4800 or 4816)
for p in '"msm_csid0":1' '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
  media-ctl -d /dev/media0 -V "$p [fmt:SRGGB10_1X10/3840x2640]" || true
done

echo "--- liveness run: $N frames (dqbuf ground truth) ---"
python3 "$HERE/sp11-liveness.py" --frames "$N" --dir "$RAWDIR" "$@"
rc=$?

echo "--- CSID stop records (ground truth cross-check) ---"
dmesg | grep 'sp11 csid stop' | tail -3
best=$(dmesg | grep 'sp11 csid stop' | tail -1 | grep -o 'TOTAL_PKTS=[0-9]*' | cut -d= -f2)
if [ -n "$best" ] && [ "$best" -gt 0 ]; then
  echo "cross-check: last stop TOTAL_PKTS=$best approx frames=$((best / 2645)) (pkts/2645)"
else
  echo "cross-check: no csid stop record found (stream may not have stopped cleanly)"
fi
echo "--- liveness rc=$rc ---"
exit "$rc"