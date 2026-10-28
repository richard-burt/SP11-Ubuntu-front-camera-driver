#!/bin/bash
# sp11-camera-prepare — bring the SP11 front-camera modules into a good state.
# Runs at boot via sp11-camera.service (root) and before manual captures.
# Binding: ccs.ko ships of_match_table entry "sony,imx681" (plus mipi-ccs*),
# so the i2c core attaches it to the sensor's i2c client on modprobe; NO
# driver_override (the attribute does not exist on this i2c bus).
#
# Bus numbers vary per boot (observed 1/2/3-0010), so the client is
# discovered from the sony,imx681 of_node instead of being hardcoded.
#
# Reboot hazard (2026-10-27): the initramfs still ships the stale in-tree
# phy-qcom-mipi-csi2 (D-PHY-only build, no /sys parameters, no C-PHY tables);
# early-boot udev loads it before this service runs, and the qcom_camss
# reload below would silently reuse that in-memory dependency. Section 1b
# detects it via srcversion and swaps the whole chain.
set -uo pipefail

fail() { echo "sp11-camera-prepare: $*" >&2; exit 1; }

UPD="/lib/modules/$(uname -r)/updates"
cphy_param="/sys/module/qcom_camss/parameters/force_cphy"
PPDIR="/sys/module/phy_qcom_mipi_csi2/parameters"

# the sensor's i2c client: address 0x10 on a per-boot-varying bus; match on
# the of_node compatible rather than the name
SENSOR_DEV=""
for d in /sys/bus/i2c/devices/*-0010; do
  grep -q "sony,imx681" "$d/of_node/compatible" 2>/dev/null && SENSOR_DEV="$(basename "$d")"
done

sensor_bound() {
  [ -n "$SENSOR_DEV" ] && [ -e "/sys/bus/i2c/drivers/ccs/$SENSOR_DEV" ]
}

# pure result only — step 1 branch depends on the return value
assert_cphy() {
  local v
  v="$(cat "$cphy_param" 2>/dev/null || echo missing)"
  case "$v" in
    1|Y) return 0 ;;
    *) return 1 ;;
  esac
}
assert_cphy_strict() {
  assert_cphy || fail "qcom_camss force_cphy wrong/missing (stale module in memory?)"
}

# rmmod with bounded retries; success = the module is GONE from sysfs
# (pipewire can already hold /dev/media0 at boot when the user session has
# Linger=yes, so a single rmmod attempt can legitimately be busy for a while)
rmmod_gone() {
  local m=$1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "/sys/module/$m" ] || return 0
    modprobe -r "$m" 2>&1 | sed 's/^/  rmmod: /'
    sleep 1
  done
  [ -d "/sys/module/$m" ] || return 0
  return 1
}

# re-discover after a reprobe can change the bus number
find_sensor() {
  SENSOR_DEV=""
  for d in /sys/bus/i2c/devices/*-0010; do
    grep -q "sony,imx681" "$d/of_node/compatible" 2>/dev/null && SENSOR_DEV="$(basename "$d")"
  done
  [ -n "$SENSOR_DEV" ]
}

# bind the sensor with retries (auto-probe can miss after camss churn)
bind_sensor() {
  find_sensor || return 1
  for _ in 1 2 3; do
    sensor_bound && return 0
    [ -n "$SENSOR_DEV" ] && echo "$SENSOR_DEV" > /sys/bus/i2c/drivers/ccs/bind 2>/dev/null
    sleep 2
    sensor_bound && return 0
    [ -x /sys/module/ccs ] || { modprobe ccs imx681_cphy=1; sleep 2; }
  done
  return 1
}

# 0. the installed modules must be present
[ -f "$UPD/qcom-camss.ko" ] || fail "updates/qcom-camss.ko missing — rerun the install script"
# the installed ccs.ko must carry the sony,imx681 OF alias (gates bind route)
if modinfo -F srcversion "$UPD/ccs.ko" >/dev/null 2>&1 && \
   ! modinfo "$UPD/ccs.ko" 2>/dev/null | grep -q 'of:N\*T\*Csony,imx681'; then
  fail "updates/ccs.ko lacks the sony,imx681 OF alias — reinstall (setup script)"
fi
[ -n "$SENSOR_DEV" ] || fail "no sony,imx681 i2c client found (DT or enumeration changed?)"

# 1. qcom_camss must be running with force_cphy. If it is loaded without it
#    (e.g. udev loaded it before modprobe.d applied), reload; FAIL if the
#    reload cannot complete (busy module = silent no-op otherwise).
if ! assert_cphy 2>/dev/null; then
  echo "reload qcom_camss with force_cphy=1"
  rmmod_gone ccs || true
  if ! rmmod_gone qcom_camss; then
    {
      echo "qcom_camss busy — device nodes still open? (pipewire?)"
      lsof /dev/media0 /dev/video* /dev/v4l-subdev* 2>/dev/null | head -10
    } >&2
    fail "cannot remove qcom_camss; force_cphy would stay off"
  fi
  modprobe qcom_camss force_cphy=1 || fail "modprobe qcom_camss force_cphy=1"
  sleep 1
fi
assert_cphy_strict

# 1b. phy version guard — the initramfs ships the stale in-tree D-PHY build
#     (no /parameters, no C-PHY receive tables); early-boot udev loads it
#     before this service runs. Swap the whole chain once, hard-fail if a
#     busy teardown persists (a silent no-op would leave the camera dead
#     until the next manual fix run).
UPDPHY="$UPD/phy-qcom-mipi-csi2.ko"
if [ -f "$UPDPHY" ]; then
  WANTP="$(modinfo -F srcversion "$UPDPHY" 2>/dev/null)"
  HAVEP="$(cat /sys/module/phy_qcom_mipi_csi2/srcversion 2>/dev/null || echo none)"
  if [ -n "$WANTP" ] && [ "$WANTP" != "$HAVEP" ]; then
    echo "stale phy in memory ($HAVEP, want $WANTP); swapping chain"
    rmmod_gone ccs || true
    if ! rmmod_gone qcom_camss; then
      {
        echo "qcom_camss busy during phy swap — device nodes still open?"
        lsof /dev/media0 /dev/video* /dev/v4l-subdev* 2>/dev/null | head -10
      } >&2
      fail "cannot remove qcom_camss for phy swap"
    fi
    if ! rmmod_gone phy_qcom_mipi_csi2; then
      {
        echo "phy busy during swap — device nodes still open?"
        lsof /dev/media0 /dev/video* /dev/v4l-subdev* 2>/dev/null | head -10
      } >&2
      fail "cannot remove stale phy_qcom_mipi_csi2"
    fi
    modprobe phy_qcom_mipi_csi2 force_cphy=1 || fail "modprobe phy-qcom-mipi-csi2"
    modprobe qcom_camss force_cphy=1 || fail "modprobe qcom_camss force_cphy=1"
    sleep 1
    assert_cphy_strict
    HAVEP="$(cat /sys/module/phy_qcom_mipi_csi2/srcversion 2>/dev/null || echo none)"
    [ "$HAVEP" = "$WANTP" ] || fail "phy still stale after reload ($HAVEP, want $WANTP)"
  fi
fi
[ -d "$PPDIR" ] || fail "phy exposes no /parameters — stale in-tree phy still in memory"

# 2. ccs: load with imx681_cphy=1, then bind the discovered sensor client
if ! sensor_bound && [ ! -d /sys/module/ccs ]; then
  modprobe ccs imx681_cphy=1 || fail "modprobe ccs"
  sleep 2
fi
bind_sensor || fail "ccs did not bind to $SENSOR_DEV"

# 3. version guard: running qcom_camss must match the installed update
WANT="$(modinfo -F srcversion "$UPD/qcom-camss.ko")"
HAVE="$(cat /sys/module/qcom_camss/srcversion 2>/dev/null || echo none)"
if [ "$WANT" != "$HAVE" ]; then
  echo "stale qcom_camss in memory ($HAVE, want $WANT); reloading"
  modprobe -r ccs || fail "rmmod ccs failed"
  modprobe -r qcom_camss || fail "rmmod qcom_camss failed"
  modprobe qcom_camss force_cphy=1
  sleep 1
  assert_cphy_strict
  modprobe ccs imx681_cphy=1
  sleep 2
  bind_sensor || fail "rebind ccs failed"
fi

# 4. phy runtime receive tuning (proven window, 2026-10-28): 1.0 Gsps AFE
#    row, CDR 0x4a, settle 0x40. MUST run last — after the version guards
#    above — so the parameters are applied to the OUT-OF-TREE phy (the
#    stale in-tree build has no /parameters).
[ -d "$PPDIR" ] || fail "no $PPDIR after reload (stale in-tree phy still loaded?)"
echo 0    > "$PPDIR/cphy_rate"   2>/dev/null || true
echo 0x4a > "$PPDIR/cphy_cdr"    2>/dev/null || true
echo 0x40 > "$PPDIR/cphy_settle" 2>/dev/null || true
[ "$(cat "$PPDIR/cphy_rate")" = "0" ] || fail "cphy_rate write did not stick"
[ "$(cat "$PPDIR/cphy_cdr")" = "74" ] || fail "cphy_cdr write did not stick"
[ "$(cat "$PPDIR/cphy_settle")" = "64" ] || fail "cphy_settle write did not stick"

# 5. final state asserts
[ -e /dev/media0 ] || fail "no /dev/media0 after module load"
echo "camera modules ready (ccs bound to $SENSOR_DEV, force_cphy active, phy updates build + cphy_rate=0 cphy_cdr=0x4a cphy_settle=0x40)"