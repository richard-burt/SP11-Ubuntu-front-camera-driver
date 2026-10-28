# Surface Pro 11 (X1E80100) front camera under Linux — status summary

The Snapdragon Surface Pro 11's front camera is a Sony IMX681 (CCS-compliant)
that transmits **MIPI C-PHY** — which mainline qcom-camss cannot receive yet.
After reverse-engineering the Windows driver blobs and building the missing
board DT from scratch, the sensor is fully working on the control side: it
identifies, binds to the generic `ccs` driver, its PLL locks in Windows'
own mode-1 configuration (3840x2160, ~61 fps internal frame counter).

On the receive side I ported Qualcomm's downstream C-PHY init (csiphy 2.1.2
register tables + exact programming order) into the kernel's CSIPHY driver,
with trio, AFE data-rate row, CDR and settle all runtime-tunable. A full sweep
located the camera on **CSIPHY2, trio 0** (not CSIPHY4 as the CRD suggests).

Current state: the CSID captures C-PHY EOTs and has gotten a packet header as
far as the CRC check, but `ERROR_CPHY_SOT_RECEPTION` persists — symbol sync
never locks, so no valid packets reach the VFE yet. CDR shows a sharp response
curve (best around 0x52–0x58); settle and core-clock changes have no effect.

Likely missing: per-sensor analog EQ/offset tuning that Qualcomm's downstream
stack loads from (non-public) CAMX tuning data. Full technical dossier,
register data and reproduction steps: **[link naar het jglathe-issue]**.

Happy to test patches — the machine has a runtime-tunable C-PHY setup ready.
