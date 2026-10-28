#!/bin/bash
# Installeer de herbouwde sp11cam.ko en herlaad hem live, daarna een snelle scan
# van de achtercamera-bus. Kost geen reboot.
set -uo pipefail
KVER=$(uname -r)
SYSDEV=/sys/bus/platform/drivers/sp11cam/sp11-cam-probe

install -m 644 /home/jeroen/sp11-camera/mod/sp11cam.ko \
        "/lib/modules/$KVER/updates/sp11cam.ko"
depmod -a

modprobe -r sp11cam 2>/dev/null
modprobe sp11cam || insmod "/lib/modules/$KVER/updates/sp11cam.ko"
sleep 1
dmesg | grep -i sp11cam | tail -3

echo "=== cpas_ahb / gdsc_clk nu ==="
for c in cam_cc_cpas_ahb_clk cam_cc_gdsc_clk; do
  d=/sys/kernel/debug/clk/$c
  [ -d "$d" ] && printf '  %-24s rate=%-10s enable=%s\n' "$c" \
    "$(cat $d/clk_rate)" "$(cat $d/clk_enable_count)" || echo "  $c: niet gevonden"
done

echo "=== achtercamera aan, bussen scannen ==="
echo 1 > "$SYSDEV/rear"; sleep 2
for b in 0 1 2 3; do
  echo "--- i2c-$b"
  i2cdetect -y -r "$b" 2>&1 | tail -n +2 | sed 's/^/    /'
done
