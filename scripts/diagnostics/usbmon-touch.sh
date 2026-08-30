#!/bin/bash
# Does the T1 actually send touch reports on the digitizer endpoint?
#
# usbmon records URBs at the host-controller layer - below hidraw, libinput and
# tiny-dfr - so this distinguishes "the device sends nothing" from "something in
# userspace is dropping it". That distinction matters: an earlier investigation
# concluded from a hidraw probe that the digitizer was silent, and it was wrong.
#
# Requires the Touch Bar to already be in USB configuration 2 (i.e. after
# scripts/install.sh, or with touchbar-t1.service started).
#
#   sudo bash usbmon-touch.sh [seconds] [output-dir]
set -u
SECS=${1:-15}
OUT=${2:-$PWD}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

USB=""
for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor")" = 05ac ] && [ "$(cat "$d/idProduct")" = 8600 ] && USB=$d
done
[ -n "$USB" ] || { echo "no 05ac:8600 iBridge found"; exit 1; }

CFG=$(cat "$USB/bConfigurationValue")
[ "$CFG" = 2 ] || { echo "device is on USB configuration $CFG, need 2"; exit 1; }

modprobe usbmon || { echo "usbmon unavailable"; exit 1; }
BUS=$(cat "$USB/busnum"); DEVNUM=$(printf '%03d' "$(cat "$USB/devnum")")
MON=/sys/kernel/debug/usb/usbmon/${BUS}u
[ -r "$MON" ] || { echo "$MON not readable (is debugfs mounted?)"; exit 1; }

# Holding the hidraw node open makes the kernel submit the interrupt URB.
RAW=$(ls -d "$USB":2.2/0003:*/hidraw/hidraw* 2>/dev/null | head -1)
RAW=${RAW:+/dev/$(basename "$RAW")}
echo "device   $(basename "$USB")  bus $BUS  devnum $DEVNUM"
echo "hidraw   ${RAW:-none}"
echo "monitor  $MON, endpoint 3 (0x83)"

LOG="$OUT/usbmon-touch-$(date +%s).txt"
timeout "$SECS" cat "$MON" > "$LOG" &
MPID=$!
RPID=""
[ -n "$RAW" ] && { timeout "$SECS" cat "$RAW" >/dev/null 2>&1 & RPID=$!; }

echo
echo ">>> TAP AND SLIDE ON THE TOUCH BAR NOW - $SECS seconds <<<"
wait $MPID 2>/dev/null
[ -n "$RPID" ] && { kill $RPID 2>/dev/null; wait $RPID 2>/dev/null; }

N=$(grep -c ":$DEVNUM:3" "$LOG" 2>/dev/null); [ -z "$N" ] && N=0
echo
echo "URB lines on endpoint 0x83: $N     (full log: $LOG)"
grep ":$DEVNUM:3" "$LOG" 2>/dev/null | head -8 | sed 's/^/  /'
echo
if [ "$N" -gt 2 ]; then
    echo "VERDICT: the T1 IS sending touch reports."
    echo "  Completions of 52 bytes whose first byte alternates 0x3N / 0x0N are"
    echo "  contact-down / contact-up. See docs/protocol.md for the layout."
else
    echo "VERDICT: nothing on the digitizer endpoint."
    echo "  Check that a driver is bound to :2.2 - with no driver the kernel"
    echo "  never submits the URB and this test cannot say anything."
fi
