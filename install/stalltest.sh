#!/bin/bash
# stall-probe: rebind sensor, stream 400 frames @31fps while a python
# writer issues S_CTRL exposure at a given cadence; report frames captured.
# usage: stalltest.sh <write-interval-ms> <phase-seconds>
set -uo pipefail
# /tmp is RAM-backed (tmpfs, 7.3 GB) — raw frame files go to disk instead
RAWDIR=/var/tmp/sp11-cam
mkdir -p "$RAWDIR"
IV=${1:?}; DUR=${2:?}
DEV=$(for d in /sys/bus/i2c/devices/*; do [ "$(basename "$(readlink -f "$d/driver" 2>/dev/null)")" = ccs ] && basename "$d"; done)
[ -n "$DEV" ] || { echo "no ccs-bound device" >&2; exit 1; }
echo "$DEV" > /sys/bus/i2c/devices/"$DEV"/driver/unbind
modprobe -r ccs 2>/dev/null
modprobe ccs
sleep 2
P=/sys/module/phy_qcom_mipi_csi2/parameters
echo 0 > "$P/cphy_rate"; echo 0x4a > "$P/cphy_cdr"
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3840,height=2640,pixelformat=pRAA >/dev/null
v4l2-ctl -d /dev/v4l-subdev26 --set-ctrl=exposure=3076
RAW="$RAWDIR/stall-${IV}ms-raw"
rm -f "$RAW"
( timeout 50 v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=400 --stream-to="$RAW" ) & SP=$!
python3 - "$IV" "$DUR" << 'PYEOF'
import os, sys, time, fcntl, struct
iv_ms = int(sys.argv[1]); dur = float(sys.argv[2])
fd = os.open("/dev/v4l-subdev26", os.O_RDWR)
buf = struct.pack("ii", 0x00980911, 3076)
t0 = time.time(); n = 0
while time.time() - t0 < dur:
    try: fcntl.ioctl(fd, 0xC008561C, buf)
    except OSError as ex: print("ioctl fail:", ex, flush=True); break
    n += 1
    time.sleep(iv_ms/1000.0)
os.close(fd)
print(f"writer done: {n} writes over {time.time()-t0:.2f}s", flush=True)
PYEOF
wait "$SP" 2>/dev/null
SZ=$(stat -c %s "$RAW" 2>/dev/null || echo 0)
echo "captured $(( SZ / 12672000 )) frames"
