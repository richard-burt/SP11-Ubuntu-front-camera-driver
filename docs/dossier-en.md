# Surface Pro 11 (x1e80100 "Denali") front camera: link + ISP fully working, frames captured — but the pixel array stays dark (13 Aug 2026)

**CURRENT BLOCKER (the question for anyone who knows this module):** the whole
chain works — C-PHY link error-free, CSID/VFE fixed, real RAW10 frames in
memory, the sensor's colour-bar test pattern arrives pixel-perfect — but the
image itself is stuck at the black level (~64/1023) with live temporal noise,
and it is invariant to EVERYTHING: 15x digital gain (register readback
confirms the write), analogue gain 0–0x3FF, exposure 1907→5888 lines, and a
flashlight into the lens. The ADC/readout clearly runs (noise varies per
frame), yet the photodiode signal path never contributes. Ruled out by
measurement: all rails (both PMIC votes from the Windows CAMF_RES blob plus
every pm8010 camera rail), the TLMM 237 GPIO in both states including a cold
power cycle in the exact Windows order (low → rails → 1 ms → high → 10 ms),
CCS software reset + clean reinit, the full 361-register Snapdragon vendor
init, and the complete Windows register set (its OP PLL of 2400 MHz however
never yields a clean C-PHY lock on our AFE tables; AndreGilerson's 1939.2 Mbps
PLL does, cleanly). Hypothesis: something outside the sensor registers gates
the pixel array on this module — a module-internal power switch, a companion
function behind the second i2c address (0x1a answers with the same CCS model
id 0x0681), or a resource Windows programs outside the camera's CAMF_RES blob.
Has anyone seen a Sony CCS-era sensor stream "black + noise, ignores
gain/exposure/light, test pattern fine"?

Side find for jglathe: the shared-gpio proxy (gpiolib_shared) reports the
consumer line physically high while TLMM pin 237 measures low — consumer
writes reach the pin inverted or not at all.

---

# Earlier that day: first frames captured — receiver-side bugs found and fixed

**FINAL UPDATE: the IMX681 front camera delivers real frames.** 3840x2640
RAW10, C-PHY on CSIPHY2/trio 0, 1.0 Gsps AFE row, CDR 0x4a (clean window
0x46–0x4e: 181k packets per 2 s, zero CRC/SOT errors), sensor programmed with
AndreGilerson's proven init table with 0x0111=3 (C-PHY). The Snapdragon Denali
is C-PHY-wired after all — the D-PHY conclusion from the Intel SP10/SP11 does
not transfer.

Three driver bugs stood between clean CSID reception and frames in memory —
all three are likely upstream-relevant for linux-media:

1. **camss-csid-680: RDI drops everything by default.** `csid_configure_rdi`
   sets `RDI_CFG1_DROP_H_EN|DROP_V_EN|CROP_H_EN|CROP_V_EN` but never programs
   the drop-pattern or crop-window registers (reset value 0) — drop/crop
   enabled with pattern/window 0 discards every pixel. Symptom: RDIN IRQ
   status (0xec) shows INPUT_SOF/SOL/EOL/EOF *and* FRAME_DROP_* on every
   frame, BUF_DONE never fires. Fix: don't set the enables (csid-gen2 doesn't)
   and write explicit keep-all patterns.
2. **camss-vfe-680: write master in the wrong mode.** `vfe_wm_start` enables
   the WM with mode 0 (QCOM_PLAIN, frame-based image checking) — every RDI
   frame is rejected with BUS_WR_IMAGE_VIOLATION (bit = WM index 24). vfe-480
   uses MODE_MIPI_RAW (1 << 16) for RDI; with that mode frames flow.
3. **Line stride alignment.** 3844 px RAW10-packed = 4805 bytes, not a
   16-byte multiple; the WM requires 16-byte-aligned lines. Cropping the
   sensor output to 3840 px (4800 bytes) resolves it. (The x1e laptops with
   working cameras all happen to have 16-aligned line widths — this may bite
   any 680-generation RDI user with an odd width.)

How the wiring was finally pinned down, in one line: a proven-correct D-PHY
transmitter (Gilerson tables, verified by register readback) into all four
CSIPHYs produced absolute silence, while the same transmitter in C-PHY mode
into csiphy2/trio0 produced packets — reception with zero errors once the CDR
was swept to 0x4a.

Remaining work: exposure/gain tuning (IMX681 analog gain register 0x0204 is
inverted: 0 = max), libcamera softISP integration, and upstreaming.
Everything below is the running history.

---

# 13 Aug (earlier): D-PHY fully excluded with a proven-correct transmitter — C-PHY on CSIPHY2/trio0 remains the only reception ever observed

**UPDATE (13 Aug 2026): the transmitter side is now beyond doubt.** I ported the
init/mode tables from AndreGilerson's imx681.c (github.com/AndreGilerson/
linux-surface-kernel, v7.0-surface-devel — the driver the Intel-SP10/SP11 work
is based on; djmulder captured real frames with these tables on the SP10):
3844x2640 RAW10, 2-lane D-PHY, link 969.6 MHz (PLL2 pre_div 3 × mult 303 →
1939.2 Mbps), 39-reg init + group-hold exposure sequence, written in his exact
order (init → 10 ms → exposure → MODE_SELECT). Verified during stream by
register readback: 0x0111=2, PLL regs exactly his values, frame counter
ticking. The CCS driver's own link-frequency selection matches (969.6 MHz,
pixel_rate 387,840,000), so PHY settle timing is computed for the real rate.

With that proven transmitter, D-PHY reception was swept across **all four
CSIPHYs** (csiphy2, csiphy4, csiphy0, csiphy1 — one DTB + reboot each,
PHY_NUM_SEL confirmed in CSID CFG0 every time, 2 lanes, clk on lane 7) plus
**all 12 CSID data-lane input permutations** (runtime dl_map param) on
csiphy2: `CSI2_RX_IRQ_STATUS` = 0x00000000 everywhere, zero errors, zero
packet counters.

**The asymmetry that now stands out:** a D-PHY transmitter into any D-PHY
receiver = absolute silence; but a C-PHY transmitter (0x0111=3) into
csiphy2/trio0 in C-PHY mode = EOTs, SOT errors with a sharp CDR response
curve, and once a packet header reaching the CRC check. That is real analog
reception, and it is the ONLY reception ever observed on this board. The
"the sensor is D-PHY" conclusion came from the *Intel* SP10/SP11 — the
Snapdragon Denali may simply be C-PHY-wired. Supporting numerology: Gilerson's
proven PLL yields ~970 Msym/s in C-PHY terms, and the 1.0-Gsps AFE row was
precisely the one with the strongest response in the earlier sweep.

**Next experiment (queued):** C-PHY on csiphy2/trio0 again, but with the
proven Gilerson sensor config and only 0x0111 flipped to 3 (new ccs modparam
imx681_cphy), AFE row 1.0 Gsps, CDR around 0x52–0x58. If SOT sync locks with
the right symbol rate, frames should follow.

Everything below is the running history.

---

# 12 Aug: IMX681 C-PHY reception FOUND on CSIPHY2 — SOT sync is the last blocker

**UPDATE (evening):** The PHY sweep found it. The front camera is wired to
**CSIPHY2 (0xace8000), trio 0** — not CSIPHY4 as the CRD analogy suggested.
With the downstream-ordered C-PHY init (2.1.2 tables) on csiphy2/trio0 the CSID
now reports, per the downstream `cam_ife_csid880.h` bit map:

- `DL0/DL1/DL2_EOT` captured (bits 0-2) — real C-PHY traffic reaching the CSID;
- `ERROR_CPHY_SOT_RECEPTION` (bit 12) persistently;
- at some AFE settings additionally `ERROR_CPHY_PH_CRC` (bit 13) — i.e. a
  packet header made it to the CRC check once symbol alignment got close;
- never `LONG_PKT`/`SHORT_PKT`; zero VFE interrupts.

Tuning observed so far: CDR (trio_base+0x78) has a sharp response curve —
dead below 0x46, best (EOTs + SOT error) around 0x52–0x58; settle count sweeps
(0x10..0x50) change nothing; CSIPHY core clk at 300 vs 480 MHz no difference;
presenting the trio as 2/3 CSID lanes → lane FIFO overflow (1 is correct).
Sensor PLL read back during streaming: Windows "mode 1" exactly — VT PLL
2160 MHz, OP PLL 2400 MHz, op_sys_div 1, RAW10, one trio; internal frame
counter ~61 fps at 3840x2160, so the symbol rate should be ~1.2 or ~2.2 Gsps
(all 8 downstream AFE rows 1.0–2.5 Gsps tried; only the 1.0–2.0 region responds).

**Remaining question for anyone who knows this PHY: what turns
`ERROR_CPHY_SOT_RECEPTION` into captured SOTs on the Gen2 2.1.2 combo PHY?**
Candidates I can't resolve from public code: per-sensor analog EQ/offset values
(downstream pulls these from CAMX tuning data, e.g. the 0x?90–0x?98 lane
registers), an exact symbol-rate-matched AFE row, or something about trio wire
order that Windows configures elsewhere. Everything below this line is the
original dossier describing how we got here.

---

# Original dossier: IMX681 streams internally, but zero C-PHY/D-PHY reception on CSIPHY4 — full findings

**TL;DR:** On the Snapdragon Surface Pro 11 I have the Sony IMX681 front camera fully
under control via the generic CCS driver (identifies, binds, PLL locks, `MODE_SELECT=1`,
internal frame counter ticks at ~61 fps), but the CAMSS receiver never sees a single
symbol — `CSI2_RX_IRQ_STATUS` stays 0x00000000 with no CRC/ECC errors, across an
exhaustive sweep of D-PHY *and* (self-ported) C-PHY reception on CSIPHY4. I'm looking
for anyone who knows the Denali camera wiring (which CSIPHY, which trio), or has
insight into x1e80100 C-PHY reception.

Kernel: jglathe `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` (7.2-rc5). All work below is
reproducible; patches and tooling available on request.

## What works (sensor side)

- Board DT written from scratch (mainline `x1e80100-microsoft-denali.dts` has no
  camera nodes): CCI buses, pm8010 rails (l1m..l7m) + pm8550 l7b/l16b, MCLK pinmux
  (`cam_aon` on gpio100 — absent from the shipped DT, sensors don't respond without
  it), reset GPIOs, camss + csiphy4 + `camera@10` on cci1/i2c-bus@1.
- Sensor identified over CCI: CCS `sensor_model_id` 0x0681, manufacturer 0x4260,
  rev 0x10, at i2c 0x10 (EEPROM 0x50 alongside; rear OV13858 VCM+sensor on cci0/1;
  IR ST VD55G0 at 0x60 on cci0/0). Matches the Windows driver blobs (MSHW0490/91/92).
- `ccs.ko` binds using static data (`ccs-sensor-4260-0681-0010.fw`) fixing four
  broken limit registers (read 0x00000000 → UBSAN shift + reject-all-link-freqs) and
  `min_pll_op_clk_freq` (0x1118 reads 0x044f3000 = fixed-point 1103.19 MHz, but the
  sensor claims IEEE 754 → decodes as 0 → single-PLL path bails with -EINVAL and no
  debug output). After that the CCS PLL calculator accepts computed link freqs.
- The full Windows init goes into the sensor: 361-register vendor init table +
  204-register mode table (both reverse-engineered from the QTI Chromatix
  `com.surface.sensormodule.ffc_imx681.bin` in the Windows DriverStore, decoder
  available), Windows' own PLL config, 1 lane per `0x0114 = 0`.
- **Proof of internal streaming:** `frame_count` (0x0005) increments ~61/s while
  streaming; `VIDIOC_STREAMON` succeeds end-to-end through camss.

## Why I believe the link is C-PHY

- Windows' validated init table writes `0x0111 = 3` (CCS: CSI-2 C-PHY signalling).
- The Windows `laneAssign` field for the front camera is 0x0000 (single lane/trio 0);
  `isComboMode = 0`.
- x1e80100 CSIPHYs are D/C combo PHYs; the sensor's own capability register claims
  D-PHY-only (0x04), but it comes from the same block with four provably-broken
  registers, and IMX681 modules exist in both modes (Leopard Imaging sells a 2-lane
  D-PHY module).
- Exhaustive D-PHY reception tests all failed silently (below) — exactly what a
  C-PHY transmitter into a D-PHY-configured receiver looks like: no activity, no
  errors.

## Receiver-side matrix (all negative, all measured via CSID registers during stream)

D-PHY (mainline camss receive path):
- CSIPHY4, physical lanes DL0..DL3 (DL0_INPUT_SEL swept, confirmed in CFG0): 0.
- CSIPHY0/1/2 (camss port + DT moved per PHY, PHY_NUM_SEL confirmed): 0.
- 1-lane and 2-lane configs; 17 computed link freqs in the sensor's feasible
  window (810–892 MHz) plus Windows' own PLL config: 0.

C-PHY (ported by me — mainline has no C-PHY receive; this kernel programs the PHY in a
separate `phy_qcom_mipi_csi2` driver, not in camss):
- Register sequence transcribed from downstream `cam_csiphy_2_1_2_hwreg.h`
  (the x1e80100 is driven by the 2.1.2 tables in mainline; its D-PHY table is
  byte-identical, PHY reports HW version 0x40010000). Full downstream ordering
  replicated from `cam_csiphy_core.c`: reset-enter (CTRL0=0x01) → lane enable
  CTRL5 = odd bit per trio (CPHY_LANE_n = BIT(1)/BIT(3)/BIT(5)) → common block
  0x1084=0, 0x108C=0, CTRL7(0x101C)=0x7A, CTRL6(0x1018)=0x01 → per-datarate AFE
  table *then* static 3ph table → reset-exit CTRL0=0x0E + 3.05 ms.
- CSID `PHY_TYPE_SEL` bit set, `DL0_INPUT_SEL` follows the trio.
- Swept at runtime: trio 0/1/2 × AFE tables 1.0/1.2/1.5/1.7/2.0 Gsps ×
  matching CSID input: `CSI2_RX_IRQ_STATUS` = 0 in every combination, zero
  packet/CRC counters. Sensor confirmed transmitting during these tests
  (0x0111=3 read back, MODE_SELECT=1, frame counter ticking).
- PHY 3ph status registers during stream: trio1 `cphy_lane_status` (0x758) reads
  a static 0x12 (others 0x00/0x01) — looks like DC line levels, no reception.

Also ruled out: MCLK (19.2 MHz, verified running *and* pinmuxed), rails (Windows
power sequence replicated, sensor answers i2c), reset GPIOs, GDSCs/clocks during
stream (IFE at 727 MHz, camnoc 400 MHz), the cam-indicator GPIO 225 interlock
theory (LED toggles, no effect), TPG (x1e80100 TPG appears non-functional in this
tree — separate issue), exposure=0, missing vendor registers (all 365 delay fields
are zero; the four loose regSettings are standard stream-on/group-hold).

## Open questions

1. **Does anyone know the Denali camera wiring?** Which CSIPHY does the front
   camera land on, and which trio/pads? (ACPI would tell, but the machine boots
   DT-mode; the Windows platform INF doesn't contain it, and the CRD analogy
   suggests csiphy4 — unverified for this board.)
2. Is there anything x1e80100-specific to C-PHY receive beyond the 2.1.2 tables —
   e.g. a combo-pad mux register that selects 3-phase mode per pad group, outside
   the csiphy register block? (The downstream techpack has no sc8380xp target to
   compare against.)
3. For the camss C-PHY WIP series (David Heidelberg et al.): I have a working,
   hang-free 2.1.2/Gen2-2.x C-PHY init flow for x1e80100 that could become the
   first user of the series on this SoC — happy to test/contribute once reception
   is proven.

## Next on my list

C-PHY reception attempts on csiphy0/1/2 (DTB variants ready, one reboot each).
