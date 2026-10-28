#!/bin/bash
# Zet een van de lane-varianten in de kernel-image en herstart daarna.
#
#   pkexec ~/sp11-camera/kies-lane.sh 0|1|2|3
#
# Achtergrond: CSID0 luistert op één fysieke lane van CSIPHY4. Uit
# CSI2_RX_CFG0 (0x00500000) blijkt dat de ontvanger correct staat -- CSIPHY4,
# één lane, D-PHY, ingang DL0 -- en tóch nul activiteit ziet, ook geen CRC- of
# ECC-fouten. Als de enkele lane van de sensor fysiek op een andere draad zit,
# luisteren we naar de verkeerde. Deze varianten proberen DL0_INPUT_SEL 1, 2 en 3.
#
# Na elke herstart controleren:
#   pkexec ~/sp11-camera/lees-csid.sh
# Zodra CSI2_RX_IRQ_STATUS niet meer nul is, komt er signaal binnen.
set -uo pipefail

L=${1:-}
case "$L" in
  0) DTB=/home/jeroen/sp11-camera/sp11-denali-cam10.dtb ;;   # het origineel, lane 0
  1|2|3) DTB=/home/jeroen/sp11-camera/sp11-denali-lane$L.dtb ;;
  phy0|phy1|phy2) DTB=/home/jeroen/sp11-camera/sp11-denali-$L.dtb ;;
  cphy) DTB=/home/jeroen/sp11-camera/sp11-denali-cphy.dtb ;;
  cphy-phy0|cphy-phy1|cphy-phy2) DTB=/home/jeroen/sp11-camera/sp11-denali-$L.dtb ;;
  dphy2) DTB=/home/jeroen/sp11-camera/sp11-denali-dphy2.dtb ;;
  dphy2-phy0|dphy2-phy1|dphy2-phy4) DTB=/home/jeroen/sp11-camera/sp11-denali-$L.dtb ;;
  *) echo "gebruik: $0 0|1|2|3|phy0|phy1|phy2|cphy|cphy-phy0|cphy-phy1|cphy-phy2" >&2; exit 2 ;;
esac

[ -f "$DTB" ] || { echo "niet gevonden: $DTB" >&2; exit 1; }
sed -i "s|^NEW=.*|NEW=$DTB|" /home/jeroen/sp11-camera/patch-uki-dtb.sh
/home/jeroen/sp11-camera/patch-uki-dtb.sh patch
echo
echo "lane $L staat klaar. Herstart, en controleer daarna met:"
echo "  pkexec ~/sp11-camera/lees-csid.sh"
