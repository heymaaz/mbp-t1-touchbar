# USB captures — how to make them, and why they are not in this repo

The reverse engineering in [protocol.md](protocol.md) came from two Wireshark
captures of macOS driving the Touch Bar on the same machine. **Neither is
committed here, and `*.pcapng` is in `.gitignore` on purpose.**

## Do not publish a raw iBridge capture

A capture of the iBridge in USB configuration 2 records the CDC-NCM link, and
that link carries far more than Touch Bar traffic:

- **Secure Element / Apple Pay.** Port 53000 carries ISO 7816 APDUs to the
  Secure Element, including GlobalPlatform `SELECT` exchanges and their
  responses. Treat anything on this port as sensitive.
- **Hardware identifiers.** Port 61001 carries MobileGestalt replies containing
  `UniqueChipID` and `BuildVersion` — values that identify your specific
  machine.
- Screen content. The DFR bulk writes on EP `0x02` are literal framebuffers of
  whatever your Touch Bar was showing.

A capture taken while the NCM link is idle — one that only touches endpoints
`0x02`, `0x85`, `0x83` and `0x87` — carries none of that, and is safe to share.
Check before you publish:

```bash
tshark -r yours.pcapng -T fields -e usb.darwin.endpoint_address | sort -u
```

If `0x04` or `0x86` appear, the NCM link was active. Either re-capture, or
strip those frames:

```bash
tshark -r yours.pcapng -Y 'usb.darwin.endpoint_address != 0x04 && usb.darwin.endpoint_address != 0x86' \
       -w safe.pcapng
```

and re-check before sharing.

## Capturing on macOS

1. Install Wireshark with the macOS USB capture support (`XHC20` interface).
2. Boot macOS, open Wireshark, capture on `XHC20`.
3. For **touch**: leave the Touch Bar idle a moment, then tap it in several
   distinct places. Short captures are best — 30 s is plenty.
4. For **sleep/wake**: start the capture, close the lid, reopen it.

The Darwin USB encapsulation carries the endpoint in
`usb.darwin.endpoint_address`, the direction in the top bit, and the payload
only on `COMPLETE` records — `SUBMIT` records for OUT transfers show a length
but no data.

Useful first look:

```bash
tshark -r capture.pcapng -q -z io,phs
tshark -r capture.pcapng -T fields -e usb.darwin.endpoint_address \
                                   -e usb.darwin.io_len | sort | uniq -c | sort -rn
```

Endpoint map for configuration 2:

| endpoint | interface | meaning |
|---|---|---|
| `0x83` IN int | 2 | **digitizer — touch reports, 52 bytes** |
| `0x02` OUT bulk | 3 | DFR framebuffer writes |
| `0x85` IN bulk | 3 | DFR preamble + acknowledgement |
| `0x04` OUT / `0x86` IN bulk | 5 | CDC-NCM — **sensitive, see above** |
| `0x87` IN int | 6 | ALS + Touch Bar backlight |
| `0x05` OUT / `0x88` IN bulk | 7 | Secure Enclave |

## Capturing on Linux

`scripts/diagnostics/usbmon-touch.sh` does this end to end. Manually:

```bash
sudo modprobe usbmon
USB=$(grep -l 8600 /sys/bus/usb/devices/*/idProduct | xargs dirname)
DEV=$(printf '%03d' "$(cat "$USB/devnum")")
sudo cat /sys/kernel/debug/usb/usbmon/1u | grep ":$DEV:3"
```

A touch report looks like:

```
ffff... C Ii:1:002:3 0:16 52 = 3241493f 00000000 ... 
                             ^^ ^^^^ ^^
                             |  X    Y
                             contact id + tip/in-range
```

usbmon's text interface truncates data to 32 bytes by default, so the
timestamp and counter at offsets 40–51 are not shown. That is fine for
confirming the device reports at all — which is the question that matters.
