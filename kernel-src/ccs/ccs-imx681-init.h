// SPDX-License-Identifier: GPL-2.0
/* IMX681-configuratie van AndreGilerson (linux-surface-kernel,
 * v7.0-surface-devel, drivers/media/i2c/imx681.c) — de tabel waarmee
 * djmulder op de Intel-SP10 aantoonbaar frames ontving (linux-surface
 * issue #2153; SP10 gebruikt daar andere PLL-waarden, dit zijn de
 * originele SP11-waarden).
 *
 * Uit Windows-I2C-traces: 3844x2640 RAW10, 2-lane D-PHY, EXCK 19,2 MHz,
 * PLL2 pre_div 3 x mult 303 -> 1939,2 MHz bitrate -> link 969,6 MHz.
 * Multi-byte registers (CCI_REG16/24/32) zijn hier uitgesplitst naar
 * losse bytes, in exact dezelfde volgorde.
 *
 * Deze reeks vervangt onze oude 361-regs vendortabel uit de
 * Snapdragon-blob (brondata blijft in ~/sp11-camera/imx681-init.txt): die zette de
 * zender mogelijk in een niet-zendende stand. Gilersons volgorde is
 * init -> ~10 ms wachten -> exposurereeks (group hold) -> MODE_SELECT=1;
 * de aanroepplek in ccs-core.c doet dat na alle eigen driverschrijfacties,
 * zodat deze bewezen waarden winnen.
 */

static const struct {
	u16 reg;
	u8 val;
} imx681_dphy_init[] = {
	/* software standby */
	{ 0x0100, 0x00 },
	/* EXCK 19,2 MHz (MHz * 256) */
	{ 0x0136, 0x13 },
	{ 0x0137, 0x33 },
	/* vendor */
	{ 0x002c, 0x05 },
	{ 0x002d, 0x05 },
	/* CSI signalling mode: D-PHY */
	{ 0x0111, 0x02 },
	/* orientation: geen flip — de ccs-driver rapporteert SRGGB10 en weet
	 * niets van onze registertabel; met H-flip (Windows AIQB) zou de
	 * echte volgorde GRBG zijn en verwisselt elke debayer R en G.
	 * Apps spiegelen selfie-preview zelf. */
	{ 0x0101, 0x00 },
	/* vendor-ontgrendelreeks (volgorde is essentieel) */
	{ 0x30eb, 0x05 },
	{ 0x30eb, 0x0c },
	{ 0x300a, 0xff },
	{ 0x300b, 0xff },
	{ 0x3532, 0xff },
	{ 0x3533, 0xff },
	/* LINE_LENGTH_PCK = 8704 (Gilerson: 7552). Met 7552 duurt een regel
	 * ~17,5 us terwijl het MIPI-pakket (4805 B @ ~2,21 Gbps) ~17,4 us
	 * kost — geen idle-tijd, ontvanger-FIFO loopt periodiek over en dropt
	 * 600-byte-blokken (de "stroken"). 8704 geeft ~13% ademruimte. */
	{ 0x0342, 0x22 },
	{ 0x0343, 0x00 },
	/* FRM_LENGTH = 3177 */
	{ 0x033e, 0x0c },
	{ 0x033f, 0x69 },
	/* cropvenster start (24-bit @0x0345 = 0x640100) */
	{ 0x0345, 0x64 },
	{ 0x0346, 0x01 },
	{ 0x0347, 0x00 },
	/* cropvenster eind (24-bit @0x0349 = 0x670b4f) */
	{ 0x0349, 0x67 },
	{ 0x034a, 0x0b },
	{ 0x034b, 0x4f },
	/* digital crop / vendor (24-bit @0x040d = 0x040a50) */
	{ 0x040d, 0x04 },
	{ 0x040e, 0x0a },
	{ 0x040f, 0x50 },
	/* X/Y_OUTPUT_SIZE = 3844 x 2640, exact Gilerson. (Eerder op 3840 gezet
	 * voor de VFE-16-byte-eis, maar de sensor bleef 3844-px-regels sturen:
	 * 4805 bytes in een 4800-stride = 5 bytes drift per regel = de
	 * diagonale glitches. Met de WM in MIPI_RAW-mode mag de regel korter
	 * zijn dan de stride, dus 3844 met stride 4816 is correct.) */
	{ 0x034c, 0x0f },
	{ 0x034d, 0x04 },
	{ 0x034e, 0x0a },
	{ 0x034f, 0x50 },
	/* VT-PLL multiplier = 225 */
	{ 0x0307, 0xe1 },
	/* PLL2: pre_div 3, mult 303 -> link 969,6 MHz (24-bit @0x030d) */
	{ 0x030d, 0x03 },
	{ 0x030e, 0x01 },
	{ 0x030f, 0x2f },
	/* initiele frameduur */
	{ 0x022a, 0x0c },
	{ 0x022b, 0x61 },
	/* vendor */
	{ 0x7e9b, 0x02 },
	{ 0x0368, 0x00 },
	{ 0xd383, 0x01 },
};

/* Eerste belichting, atomair via group hold — direct voor MODE_SELECT=1. */
static const struct {
	u16 reg;
	u8 val;
} imx681_first_exposure[] = {
	{ 0x0104, 0x01 },	/* group hold aan */
	/* FRM_LENGTH (24-bit @0x033d) = 3177 */
	{ 0x033d, 0x00 },
	{ 0x033e, 0x0c },
	{ 0x033f, 0x69 },
	/* exposure (24-bit @0x0229) = 3100 regels, vlak onder FLL 3177.
	 * (Bandpatroon in testbeelden bleek statische scène, geen 50Hz-
	 * flikker — anti-flikker-belichting is dus niet nodig.) */
	{ 0x0229, 0x00 },
	{ 0x022a, 0x0c },
	{ 0x022b, 0x1c },
	/* analoge gain 0 = 1x (LET OP: bij de IMX681 geinverteerd, 0 = laagste
	 * hier volgens Gilerson; djmulder meldt elders 0 = 16x — proven table) */
	{ 0x0204, 0x00 },
	{ 0x0205, 0x00 },
	/* digitale gain 16x vast (code 4095 = 15.99x): geen enkel gainregister
	 * latcht mid-stream (live gemeten 2026-10-28: 90 frames, analoog 960
	 * + digitaal 4095 midden-in de stream, p50/p99 frame-identiek), alleen
	 * exposure is live. AGC compenseert in fel licht met kortere
	 * belichting; de 16x verheft het plafond in donkere kamers met 2
	 * stops t.o.v. de vorige 4x (was: AGC kon zijn doeldoelwit bij
	 * max-belichting niet halen en bleef ~50/255 plafond). */
	{ 0x020e, 0x0f },
	{ 0x020f, 0xff },
	{ 0x0104, 0x00 },	/* group hold uit */
};
