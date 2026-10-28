#!/bin/bash
# SP11: privacylampje (TLMM gpio225, cam-indicator) aan zodra de camera
# streamt. Signaal: runtime-PM-status van de ISP (acb6000.isp) — "active"
# tijdens streamen, "suspended" erna. De pin houdt zijn laatste stand na
# het loslaten; een kortstondige gpioset volstaat dus per omschakeling.
set -u
DEV=/sys/devices/platform/soc@0/acb6000.isp/power/runtime_status
vorig=
while true; do
  s=$(cat "$DEV" 2>/dev/null || echo suspended)
  if [ "$s" != "$vorig" ]; then
    if [ "$s" = active ]; then
      timeout 1 gpioset -c gpiochip0 225=1 &
    else
      timeout 1 gpioset -c gpiochip0 225=0 &
    fi
    vorig=$s
  fi
  sleep 1
done
