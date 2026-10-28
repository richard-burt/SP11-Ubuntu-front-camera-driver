#!/usr/bin/env python3
"""Versie 6: bouwt voort op de uitvoer van patch_dts_v5.py.

Nieuw t.o.v. v5:
  1. De voorcamera wordt een echte sensornode (`camera@10`, compatible mipi-ccs)
     op cci1 bus 1, met eigen pinctrl-state, rails, MCLK4 en reset-gpio 237.
     De IMX681 meldt zich als CCS/SMIA++ (sensor_model_id 0x0681 op reg 0x0016),
     dus ccs.ko kan hem aansturen.
  2. csiphy@acec000 (CSIPHY4) aan, met zijn twee vdda-rails.
  3. isp@acb6000 (camss) aan, met endpoint@4 in port@3 naar de sensor.
  4. De voorcamera verdwijnt uit de sp11cam-hulpnode, anders claimen twee drivers
     dezelfde reset-GPIO en dezelfde rails. Idem gpio100 uit de mclk-state.

Sjabloon voor de bedrading: camera@36 + csiphy@acec000 + isp@acb6000 uit
x1e80100-crd.dtb. Dat board zit op dezelfde bus, MCLK en reset-pin.

Inspringing in de gedecompileerde DTS (tabs):
  soc@0 = 1, isp/csiphy = 2, ports/i2c-bus = 3, port@N = 4, endpoint = 5.

Gebruik: patch_dts_v6.py <cam5.dts> <cam6.dts>
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
dts = open(src).read()

TLMM = '0x69'
CAMCC = '0x103'
MCLK4 = '0x4f'
L7B = '0x300'        # vreg_l7b_2p8  -> vana (analoog)
L3M = '0x312'        # vreg_l3m_1p8  -> vio  (I/O)
L2C_0P8 = '0x2a6'    # vreg_l2c_0p8  -> csiphy analoog
L1C_1P2 = '0x2a5'    # vreg_l1c_1p2  -> csiphy digitaal
FRONT_PINS = '0x321'
SENS_EP = '0x330'
CAMSS_EP = '0x331'


def eis(voorwaarde, tekst):
    if not voorwaarde:
        raise SystemExit('AFGEBROKEN: ' + tekst)


# ---------------------------------------------------------------- 1. opruimen
dts, n = re.subn(
    r'\n\t{4}mclk4-pins \{\n\t{5}pins = "gpio100";'
    r'\n\t{5}function = "cam_aon";'
    r'\n\t{5}drive-strength = <0x10>;\n\t{5}bias-disable;\n\t{4}\};\n',
    '\n', dts)
eis(n == 1, 'mclk4-pins niet uit de mclk-state gehaald (%d treffers)' % n)

for prop in ('front-1p8-supply', 'front-2p8-supply', 'front-reset-gpios'):
    dts, n = re.subn(r'\n\t\t%s = <[^;]*>;' % prop, '', dts)
    eis(n <= 1, 'meerdere %s gevonden' % prop)

# ------------------------------------------ 2. eigen pinctrl-state voor de front
front_state = '''
			cam-front-default-state {
				phandle = <%s>;

				mclk4-pins {
					pins = "gpio100";
					function = "cam_aon";
					drive-strength = <0x10>;
					bias-disable;
				};

				reset-n-pins {
					pins = "gpio237";
					function = "gpio";
					drive-strength = <0x02>;
					bias-disable;
				};
			};
''' % FRONT_PINS

m = re.search(r'\n\t{3}cam-mclk-default-state \{.*?\n\t{3}\};\n', dts, re.S)
eis(m, 'cam-mclk-default-state niet gevonden')
dts = dts[:m.end()] + front_state + dts[m.end():]

# ------------------------------------------------------- 3. csiphy4 aanzetten
m = re.search(r'csiphy@acec000 \{.*?status = "(disabled)";', dts, re.S)
eis(m, 'csiphy@acec000 met status disabled niet gevonden')
dts = dts[:m.start(1)] + 'okay' + dts[m.end(1):]

m = re.search(r'csiphy@acec000 \{.*?status = "okay";', dts, re.S)
extra = ('\n\t\t\tvdda-0p8-supply = <%s>;'
         '\n\t\t\tvdda-1p2-supply = <%s>;'
         '\n\t\t\tphy-type = <0x0a>;') % (L2C_0P8, L1C_1P2)
dts = dts[:m.end()] + extra + dts[m.end():]

# ---------------------------------------------- 4. camss aan + endpoint erbij
m = re.search(r'isp@acb6000 \{.*?status = "(disabled)";', dts, re.S)
eis(m, 'isp@acb6000 met status disabled niet gevonden')
dts = dts[:m.start(1)] + 'okay' + dts[m.end(1):]

camss_ep = '''
					endpoint@4 {
						reg = <0x04>;
						clock-lanes = <0x07>;
						data-lanes = <0x00>;
						remote-endpoint = <%s>;
						phandle = <%s>;
					};
''' % (SENS_EP, CAMSS_EP)

m = re.search(
    r'isp@acb6000 \{.*?port@3 \{\n\t{5}reg = <0x03>;'
    r'\n\t{5}#address-cells = <0x01>;\n\t{5}#size-cells = <0x00>;\n', dts, re.S)
eis(m, 'port@3 van isp@acb6000 niet gevonden')
dts = dts[:m.end()] + camss_ep + dts[m.end():]

# ------------------------------------------------------- 5. de sensornode zelf
# Windows' modus-tabel zet 0x0114 = 0, en de driver schrijft daar lanes-1 in:
# dus EEN lane. De DT moet daarop aansluiten, anders verwacht camss een ander
# aantal dan de sensor verstuurt.
# De sensor meldt csi_dphy_lane_mode_capability = 0x3, oftewel alleen 1 of 2
# lanes -- en csi_signaling_mode_capability = 4, dus D-PHY en geen C-PHY. Wij
# hadden vier lanes geconfigureerd; dat kan de sensor niet en dan zendt hij niets.
# Windows gebruikt voor de volle resolutie een OP-PLL van 9,6 x 208 = 1996,8 MHz.
# link-frequencies is verplicht en de juiste waarde voor de IMX681 is onbekend.
# Lijst BEREKEND uit de gemeten limieten en de PLL-trace: vt_pix = link/5 moet
# tussen 162 en 180 MHz liggen en op_pix onder 178,58, dus link tussen 810 en 892
# MHz. Daarbinnen zijn alleen de exacte PLL-uitkomsten mogelijk: voordeler 2 geeft
# een ingang van 9,6 MHz, en link = multiplier x 9,6 / 2. Vandaar deze 17 waarden.
# Oude toelichting: lijst afgeleid uit de GEMETEN limieten (zie limieten.txt): op_sys_clk moet
# 1050-2500 MHz zijn, wat bij DDR neerkomt op 525-1250 MHz link. De lagere
# waarden staan erbij voor het geval de driver anders rekent. De driver
# kiest zelf de eerste die met zijn PLL uitkomt. Scheelt een reboot per gok.
sensor = '''
				camera@10 {
					compatible = "mipi-ccs-1.1", "mipi-ccs";
					reg = <0x10>;
					reset-gpios = <%s 0xed 0x01>;
					pinctrl-0 = <%s>;
					pinctrl-names = "default";
					clocks = <%s %s>;
					assigned-clocks = <%s %s>;
					assigned-clock-rates = <0x124f800>;
					vana-supply = <%s>;
					vio-supply = <%s>;
					rotation = <0x00>;
					orientation = <0x00>;

					port {

						endpoint {
							data-lanes = <0x01>;
							bus-type = <0x04>;
							link-frequencies = <0x00 0x3059ee00 0x00 0x30a32c00 0x00 0x30ec6a00 0x00 0x3135a800 0x00 0x317ee600 0x00 0x31c82400 0x00 0x32116200 0x00 0x325aa000 0x00 0x32a3de00 0x00 0x32ed1c00 0x00 0x33365a00 0x00 0x337f9800 0x00 0x33c8d600 0x00 0x34121400 0x00 0x345b5200 0x00 0x34a49000 0x00 0x34edce00>;
							remote-endpoint = <%s>;
							phandle = <%s>;
						};
					};
				};
''' % (TLMM, FRONT_PINS, CAMCC, MCLK4, CAMCC, MCLK4, L7B, L3M, CAMSS_EP, SENS_EP)

# De enige bedrade bus van ac16000 is i2c-bus@1 (pinctrl claimt maar twee pinnen).
m = re.search(r'cci@ac16000 \{.*?i2c-bus@1 \{\n(?:\t{4}[^\n]*\n)*', dts, re.S)
eis(m, 'i2c-bus@1 van cci@ac16000 niet gevonden')
dts = dts[:m.end()] + sensor + dts[m.end():]

open(dst, 'w').write(dts)
print('geschreven: %s' % dst)
