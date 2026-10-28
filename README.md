# SP11-Ubuntu-front-camera-driver

Sony IMX681 front camera on the **Surface Pro 11 (Snapdragon X Elite, x1e80100
"Denali")** under **Ubuntu Linux** — kernel bring-up, device tree, tuning and
user-space plumbing that makes the built-in webcam work at Windows-comparable
image quality, with boot automation, a stream-liveness instrument and the
freeze-fix patches documented and included.

## What works

- Camera enumerates in PipeWire / libcamera as **"Built-in Front Camera"**
  (GNOME Snapshot, browsers via the WebRTC PipeWire camera backend).
- C-PHY lane bring-up on the x1e80100 CAMSS/CSID receive path
  (`force_cphy`, `cphy_rate=0`, `cphy_cdr=0x74`, `cphy_settle=0x40`).
- Auto-exposure converges to **Windows parity**: white plate renders
  ~174–188/255 in the same daylight scene Windows shows 174–183.
- Streaming sessions are **stable** (800-frame instrument baseline, 800/800
  frames, no gaps, 32.7 s continuous).
- Colour: factory CCM/white-balance tuning from the Windows driver; grey-world
  AWB gains land within ~5 % of ideal under the shipped soft-IPA.
- Privacy LED follows streaming.
- The known "camera freezes a few minutes in" defect is **root-caused and
  fixed** (see *Freeze fix* below).

## Freeze fix (the interesting part)

The sensor (CCS driver, IMX681 over CCI) accepts mid-stream writes of its
exposure register, but **no gain register latches mid-stream**, and the
libcamera soft-IPA's digital-gain extension hammers
`V4L2_CID_DIGITAL_GAIN` every frame once its gain ladder saturates. Those
stale writes burst CCI traffic during streaming and freeze image delivery
(~100 frames after gain-max; then permanently stale frames and eventual
stream death).

The fix (in `kernel-src/ccs/`, files `ccs-core.c`, `ccs.h`,
`ccs-imx681-init.h`):

1. `V4L2_CID_DIGITAL_GAIN` is a cached **no-op** for IMX681 (no CCI traffic);
2. mid-stream exposure/gain writes are throttled (≤5/s);
3. stream-on initial digital gain is pinned to ≈15.99× so the AGC ladder
   starts near its equilibrium;
4. the sensor media entity is renamed `imx681` when the DT compatible is
   `sony,imx681` so the soft-IPA finds its `CameraSensorHelperImx681` and the
   imx681 tuning file.

Result: sessions converge and *hold* (repeatable `std ≤ 0.08` over the last
150 frames).

## Repo layout

| Path | Contents |
|---|---|
| `kernel-src/{camss,ccs,phy}/` | Camera-stack kernel sources with the patches applied (based on the public `karsies-wq/sp11-imx681-linux` work; see *Provenance*) |
| `dtb/` | Camera DT overlay sources, patchers and patched blobs |
| `install/` | Bring-up, recovery, deploy, debug and sweep scripts + the canonical `libcamera-smiapp.yaml` tuning |
| `tools/` | `sp11-liveness.{py,sh}` — per-frame DQBUF stream-liveness instrument (ground truth for stall/death diagnosis) |
| `userspace/` | libcamera patches (upstream soft-IPA patch and the SP11 patch set in `sp11-patches/`), tuning YAMLs, PipeWire conf, systemd units |
| `sensor-data/` | factory init register dumps, mode tables, CCS firmware, sensor tuning YAML |
| `docs/` | base-work dossier and notes |
| `scripts/` | base-work debug utilities (raw→PNG, CCI/C-PHY readers, sweeps) |

## Provenance

The `kernel-src/`, `userspace/`, `sensor-data/`, `docs/` and `scripts/` trees
are derived from the public work at
[jglathe/linux_ms_dev_kit](https://github.com/jglathe/linux_ms_dev_kit)` (x1e80100
kernel tree) and [karsies-wq/sp11-imx681-linux](https://github.com/karsies-wq/sp11-imx681-linux)
(commit `b08f76f`), extended with the freeze-fix patches above, the boot
prepare service (`install/sp11-camera-prepare.sh`, dynamic sensor-client
discovery — bus number varies per boot) and the liveness instrument.
GPL-2.0 throughout, matching the base work.

## Quick start (already-installed systems)

The runtime system this was developed on installs:

- `kernel-src/` modules built to `/lib/modules/$(uname -r)/updates/
  {ccs,qcom-camss,phy-qcom-mipi-csi2}.ko`;
- CCS firmware `/lib/firmware/ccs/ccs-sensor-4260-0681-0010.fw`;
- tuning `/usr/share/libcamera/ipa/simple/{smiapp,imx681}.yaml`;
- boot service `sp11-camera.service` → `/usr/local/sbin/sp11-camera-prepare`;
- user-space helpers in `install/` (notably `sp11-camera-full-reload.sh` —
  the reliable stream-wedge recovery if you ever need it).

`install/sp11-camera-setup.sh` performs the bulk of a fresh install.

## Known issues / in progress

- Soft-IPA has no noise-reduction stage (dim-room grain; more light is the
  free mitigation) and no lens-dewarp (Windows applies MFT LDC; FOV parity
  holds anyway).
- AE/AWB convergence: stream start settles in a few seconds (fast ladder +
  max-exposure start in `sp11-patches/`); during that ~1–2 s window the
  auto white balance is still converging and early captures can look
  colour-shifted — let the preview settle before judging colour.

## Upstreaming candidates

Everything on the base work's list, plus: the DIGITAL_GAIN no-op/throttle
approach for sensors whose gain registers do not latch mid-stream, and the
`imx681` entity-name mapping for the soft-IPA helper/tuning lookup.

## AI disclosure

This work was done in close collaboration with an AI assistant (Claude via
Claude Code for the base work; this repo's freeze-fix, instrumentation and
documentation via OpenCode): debugging strategy, patches, scripts and
documentation largely AI-written, with the human directing, running every
on-device experiment and making the decisions. All results were verified on
real hardware; treat the code with the same review scrutiny you would give
any bring-up patchset.