#!/bin/bash
# STAGE 2: enable the Touch Bar units at boot.
#
# Run this ONLY after install-persistence.sh has passed its live test and the
# lockout canaries were clean (logind seats = seat0 only; the appletbdrm DRM
# card has no master-of-seat tag; i915 does).
#
# Run as root:  sudo bash enable-persistence.sh
set -u

say() { echo; echo "===== $* ====="; }

say "0. SNAPSHOT"
mkdir -p /.snapshots
SNAP=/.snapshots/pre-claude-$(date +%F)
[ -e "$SNAP" ] && SNAP="${SNAP}-$(date +%H%M%S)"
btrfs subvolume snapshot -r / "$SNAP" || { echo "!! SNAPSHOT FAILED - ABORTING"; exit 1; }
btrfs subvolume list / | grep -q "${SNAP#/}" || { echo "!! snapshot not listed - ABORTING"; exit 1; }
echo "  ROLLBACK TARGET: $SNAP"

say "1. re-check the lockout canaries BEFORE enabling"
FAIL=0
SEATS=$(loginctl list-seats 2>/dev/null | grep -c '^seat')
SEATLIST=$(loginctl list-seats 2>/dev/null | tr '\n' ' ')
echo "  logind seats: $SEATLIST"
if [ "$SEATS" -ne 1 ] || ! loginctl list-seats 2>/dev/null | grep -qx 'seat0'; then
    echo "  !! more than seat0 exists - REFUSING to enable"
    FAIL=1
fi
for c in /sys/class/drm/card[0-9]; do
    drv=$(readlink -f "$c/device/driver" 2>/dev/null | xargs -r basename)
    tags=$(udevadm info "$c" 2>/dev/null | grep -oP 'CURRENT_TAGS=\K.*')
    echo "  $(basename "$c") ($drv) tags=${tags:-none}"
    case "$drv" in
        appletbdrm) case "$tags" in *master-of-seat*)
            echo "  !! the Touch Bar card is master-of-seat - REFUSING to enable"; FAIL=1;; esac ;;
        i915) case "$tags" in *master-of-seat*) ;; *)
            echo "  !! the Intel GPU LOST master-of-seat - REFUSING to enable"; FAIL=1;; esac ;;
    esac
done
[ -f /etc/udev/rules.d/71-seat.rules ] || { echo "  !! 71-seat.rules override missing - REFUSING"; FAIL=1; }
[ "$FAIL" = 0 ] || { echo; echo "ABORTED - fix the above first."; exit 1; }
echo "  canaries OK"

say "2. enable"
systemctl enable touchbar-t1.service tiny-dfr.service 2>&1 | sed 's/^/  /'
echo "  touchbar-t1: $(systemctl is-enabled touchbar-t1.service)"
echo "  tiny-dfr:    $(systemctl is-enabled tiny-dfr.service)"

say "3. ordering-cycle check after enabling"
systemctl daemon-reload
if systemd-analyze verify multi-user.target 2>&1 | grep -qi 'ordering cycle\|Found ordering'; then
    echo "  !! ORDERING CYCLE DETECTED - disabling again"
    systemctl disable touchbar-t1.service tiny-dfr.service
    exit 1
fi
systemd-analyze verify /etc/systemd/system/touchbar-t1.service \
                       /etc/systemd/system/tiny-dfr.service 2>&1 | sed 's/^/  /'
echo "  no ordering cycle"

say "DONE - ENABLED AT BOOT"
echo "  snapshot / rollback target: $SNAP"
cat <<'EOF'

  BEFORE YOU REBOOT, read this:

  1. Know how to reach a TTY: Ctrl+Alt+F2, log in as your user.
  2. If the desktop does not come up, from that TTY:

       sudo systemctl disable --now tiny-dfr touchbar-t1
       sudo reboot

     That alone undoes everything this script did.

  3. If that is not enough, roll back wholesale to the snapshot printed above.

  Now reboot once, deliberately, and check the Touch Bar comes up lit and
  responsive on its own.
EOF
