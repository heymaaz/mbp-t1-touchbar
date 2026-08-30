#!/bin/bash
# Install the T1 Touch Bar stack. Leaves everything DISABLED at boot;
# run scripts/enable.sh once you have confirmed it works in a live session.
#
#   sudo bash scripts/install.sh
#
# Assumes Arch (pacman, DKMS). Adapt paths for other distributions.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TDFR_SRC=${TINY_DFR_SRC:-$REAL_HOME/src/tiny-dfr}
VER=1.0

say()  { echo; echo "===== $* ====="; }
die()  { echo "install: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"

say "0. preflight"
FOUND=""
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor")" = 05ac ] && [ "$(cat "$d/idProduct")" = 8600 ] && FOUND=$d
done
[ -n "$FOUND" ] || die "no 05ac:8600 iBridge - this is not a T1 Mac (or it is powered off)"
echo "  iBridge at $(basename "$FOUND")"

modinfo hid-multitouch 2>/dev/null | grep -q 'p00008302' \
    || die "this kernel's hid-multitouch has no Apple Touch Bar class; need Linux >= 6.15"
echo "  hid-multitouch has MT_CLS_APPLE_TOUCHBAR"

for c in dkms python3 zstd; do command -v $c >/dev/null || die "missing dependency: $c"; done
[ -d /usr/lib/modules/"$(uname -r)"/build ] || die "kernel headers missing for $(uname -r)"

say "1. snapshot"
if command -v btrfs >/dev/null && btrfs subvolume show / >/dev/null 2>&1; then
    mkdir -p /.snapshots
    SNAP=/.snapshots/pre-touchbar-t1-$(date +%F-%H%M%S)
    btrfs subvolume snapshot -r / "$SNAP" || die "snapshot failed"
    echo "  ROLLBACK TARGET: $SNAP"
else
    echo "  !! / is not btrfs - no snapshot taken."
    echo "     Make your own backup before continuing. Ctrl-C now to stop."
    sleep 10
fi

say "2. kernel modules (DKMS)"
DK=/usr/src/appletbdrm-t1-$VER
dkms remove appletbdrm-t1/$VER --all >/dev/null 2>&1 || true
rm -rf "$DK"; mkdir -p "$DK"
cp "$REPO"/kernel/appletbdrm.c "$REPO"/kernel/hid-appletb-bl.c \
   "$REPO"/kernel/Makefile "$REPO"/kernel/dkms.conf "$DK"/
dkms add    appletbdrm-t1/$VER >/dev/null
dkms build  appletbdrm-t1/$VER 2>&1 | tail -2 | sed 's/^/  /'
dkms install --force appletbdrm-t1/$VER 2>&1 | tail -2 | sed 's/^/  /'
depmod -a
modinfo appletbdrm | grep -q p8600 || die "appletbdrm still lacks 05ac:8600"
echo "  appletbdrm + hid-appletb-bl installed"

say "3. tiny-dfr (patched)"
if [ ! -d "$TDFR_SRC" ]; then
    command -v git >/dev/null || die "git needed to fetch tiny-dfr"
    sudo -u "$REAL_USER" git clone https://github.com/WhatAmISupposedToPutHere/tiny-dfr "$TDFR_SRC"
fi
if ! grep -q 'iBridge Touchpad' "$TDFR_SRC/src/main.rs"; then
    sudo -u "$REAL_USER" patch -d "$TDFR_SRC" -p1 \
        < "$REPO"/userspace/tiny-dfr-t1-digitizer-name.patch
    echo "  applied the T1 digitizer-name patch"
else
    echo "  patch already applied"
fi
command -v cargo >/dev/null || die "cargo needed to build tiny-dfr (pacman -S rust)"
sudo -u "$REAL_USER" sh -c "cd '$TDFR_SRC' && cargo build --release" 2>&1 | tail -3 | sed 's/^/  /'
[ -e /usr/local/bin/tiny-dfr ] && [ ! -e /usr/local/bin/tiny-dfr.bak ] \
    && cp -a /usr/local/bin/tiny-dfr /usr/local/bin/tiny-dfr.bak
install -m755 "$TDFR_SRC/target/release/tiny-dfr" /usr/local/bin/tiny-dfr
mkdir -p /usr/share/tiny-dfr
cp -r "$TDFR_SRC"/share/tiny-dfr/. /usr/share/tiny-dfr/
echo "  /usr/local/bin/tiny-dfr + /usr/share/tiny-dfr"

say "4. configuration"
mkdir -p /etc/tiny-dfr
[ -e /etc/tiny-dfr/config.toml ] \
    && echo "  /etc/tiny-dfr/config.toml exists - left alone" \
    || { install -m644 "$REPO"/system/tiny-dfr-config.toml /etc/tiny-dfr/config.toml
         echo "  /etc/tiny-dfr/config.toml (media layer default)"; }
echo uinput > /etc/modules-load.d/uinput.conf

say "5. seat rules + pacman hook"
install -m755 "$REPO"/system/gen-seat-rules.sh /usr/local/bin/touchbar-t1-gen-seat-rules
/usr/local/bin/touchbar-t1-gen-seat-rules || die "seat rules generation failed"
mkdir -p /etc/pacman.d/hooks
install -m644 "$REPO"/system/pacman-hooks/95-touchbar-t1-seat-rules.hook /etc/pacman.d/hooks/
echo "  pacman hook installed - seat rules regenerate after systemd upgrades"

say "6. system scripts + units (NOT enabled)"
install -m755 "$REPO"/system/touchbar-t1-setup   /usr/local/bin/touchbar-t1-setup
install -m755 "$REPO"/system/touchbar-activate   /usr/local/bin/touchbar-activate
install -m644 "$REPO"/system/touchbar-t1.service /etc/systemd/system/
install -m644 "$REPO"/system/tiny-dfr.service    /etc/systemd/system/
systemctl daemon-reload
# The Tschalar apple-ibridge stack forces USB configuration 1, which has no
# display interface. It cannot coexist with this one.
systemctl disable --now apple-ibridge.service 2>/dev/null || true
cat > /etc/modprobe.d/blacklist-apple-ib.conf <<'EOF'
# The T1 Touch Bar is a DRM display driven by appletbdrm, not an HID gadget.
# These modules force USB configuration 1, which has no display interface.
blacklist apple_ib_tb
blacklist apple_ib_als
blacklist apple_ibridge
EOF
echo "  units installed, disabled"

say "7. live test"
systemctl start touchbar-t1.service
journalctl -u touchbar-t1.service --no-pager -b -n 20 | sed 's/^/  /'
systemctl start tiny-dfr.service
sleep 5
echo "  tiny-dfr: $(systemctl is-active tiny-dfr.service)"

say "8. health check"
bash "$REPO"/scripts/doctor.sh || true

cat <<EOF

===== INSTALLED, NOT YET ENABLED AT BOOT =====

  The Touch Bar should be lit now, showing media keys. Hold fn for F1-F12.
  Verify touch actually works:

      python3 $REPO/scripts/diagnostics/watch-endtoend.py

  Only once that passes, enable at boot:

      sudo bash $REPO/scripts/enable.sh

  To undo everything:

      sudo bash $REPO/scripts/uninstall.sh
EOF
