#!/bin/bash
# sp11-camera-led — privacy LED (TLMM gpio225, cam-indicator) follows the
# ISP runtime-PM status: "active" while the camera streams.
set -u
DEV=/sys/devices/platform/soc@0/acb6000.isp/power/runtime_status
prev=
while true; do
  s=$(cat "$DEV" 2>/dev/null || echo suspended)
  if [ "$s" != "$prev" ]; then
    if [ "$s" = active ]; then
      timeout 1 gpioset -c gpiochip0 225=1 &
    else
      timeout 1 gpioset -c gpiochip0 225=0 &
    fi
    prev=$s
  fi
  sleep 1
done