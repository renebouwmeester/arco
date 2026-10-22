#!/bin/bash
# Proef (22 okt 2026): de Pi-geluidskaart via configfs in plaats van g_audio — om hem een naam te kunnen geven. Met g_audio
# noemt de Mac hem "Playback Inactive" (de naam van zijn stream-interface; iProduct "Arco Pi" komt wel aan maar CoreAudio
# kiest die niet). Hier krijgen de functie, de bediening, de terminals en de klokken allemaal "Arco Pi".
# Alleen tot de volgende start: daarna laadt de Pi weer g_audio (arco-gadget.sh).
# UITKOMST 22 okt 2026: ook zo "Playback Inactive" — CoreAudio neemt de naam van de stream-interface, en die ligt in f_uac2
# vast (niet in configfs). Bewaard als proef; g_audio blijft.
#   sudo bash ~/arco-gadget-cfs.sh aan   — g_audio eruit, deze erin
#   sudo bash ~/arco-gadget-cfs.sh uit   — deze eruit, g_audio terug
set -e
G=/sys/kernel/config/usb_gadget/arcopi
NAAM="Arco Pi"
case "$1" in
  aan)
    modprobe -r g_audio 2>/dev/null || true
    modprobe libcomposite
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
    mkdir -p $G && cd $G
    echo 0x1d6b > idVendor; echo 0x0101 > idProduct; echo 0x0100 > bcdDevice; echo 0x0200 > bcdUSB
    mkdir -p strings/0x409
    echo "Arco" > strings/0x409/manufacturer; echo "$NAAM" > strings/0x409/product; echo "arcopi1" > strings/0x409/serialnumber
    mkdir -p functions/uac2.usb0 && cd functions/uac2.usb0
    echo 44100,48000,88200,96000,176400,192000 > c_srate
    echo 3 > c_ssize; echo 3 > c_chmask; echo 0 > p_chmask
    for a in function_name if_ctrl_name clksrc_in_name clksrc_out_name c_it_name c_ot_name c_it_ch_name; do
      [ -e $a ] && echo "$NAAM" > $a
    done
    cd $G
    mkdir -p configs/c.1/strings/0x409
    echo "$NAAM" > configs/c.1/strings/0x409/configuration
    echo 100 > configs/c.1/MaxPower
    ln -sf $G/functions/uac2.usb0 configs/c.1/
    ls /sys/class/udc | head -1 > UDC
    echo "aan: configfs-gadget \"$NAAM\" op $(cat UDC)" ;;
  uit)
    if [ -d $G ]; then
      cd $G
      echo "" > UDC 2>/dev/null || true
      rm -f configs/c.1/uac2.usb0
      rmdir configs/c.1/strings/0x409 configs/c.1 functions/uac2.usb0 strings/0x409 2>/dev/null || true
      cd / && rmdir $G
    fi
    modprobe g_audio
    echo "uit: g_audio terug" ;;
  *) echo "gebruik: sudo bash ~/arco-gadget-cfs.sh aan|uit"; exit 1 ;;
esac
