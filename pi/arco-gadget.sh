#!/bin/bash
# De Pi als USB-geluidskaart voor de iPhone (22 okt 2026, Arco-proef "virtuele DAC"): de USB-C-poort wordt een apparaat
# (dwc2 in peripheral-modus) en meldt zich als UAC2-audio met 44,1–192 kHz, 24-bit, stereo, alleen afspelen naar de Pi.
#   sudo bash ~/arco-gadget.sh aan    — instellen; daarna uitzetten, de kabels omzetten (iPhone → hub → Pi) en weer aan
#   sudo bash ~/arco-gadget.sh uit    — alles terug zoals het was
#   sudo bash ~/arco-gadget.sh herlaad — de module opnieuw laden (na een andere naam of andere opties)
set -e
CFG=/boot/firmware/config.txt
LINE="dtoverlay=dwc2,dr_mode=peripheral"
case "$1" in
  aan)
    grep -qxF "$LINE" "$CFG" || echo "$LINE" >> "$CFG"
    echo g_audio > /etc/modules-load.d/arco-gadget.conf
    # De naam (22 okt 2026): zonder productnaam noemde de Mac hem naar zijn afspeelinterface, "Playback Inactive".
    echo "options g_audio c_srate=44100,48000,88200,96000,176400,192000 c_ssize=3 c_chmask=3 p_chmask=0 iProduct=\"Arco Pi\" iManufacturer=Arco" > /etc/modprobe.d/arco-gadget.conf
    echo "aan: na de volgende start is de USB-C-poort een geluidskaart (of meteen: sudo bash ~/arco-gadget.sh herlaad)" ;;
  herlaad)
    # De module opnieuw, met de opties van nu — de iPhone of Mac ziet het apparaat even verdwijnen en terugkomen.
    modprobe -r g_audio && modprobe g_audio
    echo "herladen: $(cat /etc/modprobe.d/arco-gadget.conf)" ;;
  uit)
    sed -i "\|^$LINE\$|d" "$CFG"
    rm -f /etc/modules-load.d/arco-gadget.conf /etc/modprobe.d/arco-gadget.conf
    echo "uit: na de volgende start is de USB-C-poort weer gewoon" ;;
  *) echo "gebruik: sudo bash ~/arco-gadget.sh aan|uit|herlaad"; exit 1 ;;
esac
