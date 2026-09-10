#!/bin/bash
# Remove everything install.sh added and return the Touch Bar to stock
# (USB configuration 1, no drivers bound, panel dark).
#
#   sudo bash scripts/uninstall.sh
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

if command -v btrfs >/dev/null && btrfs subvolume show / >/dev/null 2>&1; then
    mkdir -p /.snapshots
    SNAP=/.snapshots/pre-touchbar-uninstall-$(date +%F-%H%M%S)
    btrfs subvolume snapshot -r / "$SNAP" && echo "snapshot: $SNAP"
fi

systemctl disable --now touchbar-t1-appmap.service 2>/dev/null
systemctl disable --now tiny-dfr.service touchbar-t1.service 2>/dev/null
rm -f /etc/systemd/system/touchbar-t1.service /etc/systemd/system/tiny-dfr.service \
      /etc/systemd/system/touchbar-t1-appmap.service
systemctl daemon-reload

rm -f /usr/local/bin/touchbar-t1-setup /usr/local/bin/touchbar-activate \
      /usr/local/bin/touchbar-t1-gen-seat-rules /usr/local/bin/touchbar-t1-appmap
[ -e /usr/local/bin/tiny-dfr.bak ] \
    && mv /usr/local/bin/tiny-dfr.bak /usr/local/bin/tiny-dfr \
    || rm -f /usr/local/bin/tiny-dfr
rm -rf /usr/share/tiny-dfr /etc/tiny-dfr

rm -f /etc/pacman.d/hooks/95-touchbar-t1-seat-rules.hook
rm -f /etc/udev/rules.d/71-seat.rules          # restores systemd's stock file
rm -f /etc/modprobe.d/blacklist-apple-ib.conf
rm -f /etc/modules-load.d/uinput.conf
udevadm control --reload-rules

dkms remove appletbdrm-t1/1.0 --all 2>/dev/null
rm -rf /usr/src/appletbdrm-t1-1.0
depmod -a

for m in hid_multitouch appletbdrm hid_appletb_bl; do modprobe -r $m 2>/dev/null; done
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor")" = 05ac ] && [ "$(cat "$d/idProduct")" = 8600 ] \
        && echo 1 > "$d/bConfigurationValue" 2>/dev/null
done

echo
echo "Removed. The Touch Bar is back to stock (dark)."
echo "Reboot to confirm a clean state."
