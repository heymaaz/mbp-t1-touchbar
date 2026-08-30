# T1 iBridge protocol notes

Everything here was derived from USB captures of macOS 12.7.6 on a
MacBookPro13,2, cross-checked against `usbmon` on Linux and against the
device's own descriptors. Where something is unverified it says so.

## 1. USB configurations

Read from the raw device descriptors (`/dev/bus/usb/BBB/DDD` is world-readable,
so no root needed):

```
config 1  4 interfaces   webcam, HID keyboard (83 B), HID 0xff12 (634 B)
config 2  8 interfaces   webcam, digitizer (782 B), DFR display (class 0x10),
                         CDC-NCM, HID 0xff12 (634 B), SEP (ff/f9/11)
config 3  6 interfaces   config 1 + CDC-NCM
```

Config 3 is **not** "config 2 minus the display" — it has the keyboard, not the
digitizer, and no display interface at all.

The 634-byte 0xff12 interface (ALS + Touch Bar backlight) is present in **all
three** configurations.

### The config-1 keyboard descriptor

83 bytes: a boot keyboard, plus

```
05 ff 09 04     Usage Page 0xff (vendor), Usage 0x04
85 02           Report ID 2
15 00 26 ff 00 75 08 95 01 91 02    1-byte Output report
```

That Output report is the `mode` register `apple-ib-tb` writes with
SET_REPORT `wValue=0x0202`. Configuration 2's interface 2 has no such report,
which is why it STALLs the mode command — that is a config-1 concept and a
dead end in config 2.

## 2. The digitizer (config 2, interface 2, EP 0x83, interrupt IN)

Report descriptor: 782 bytes, no report IDs, input only.
Raw copy in `digitizer-report-descriptor.bin`.

Structure: a `Digitizers/TouchPad` application collection containing **ten**
`Finger` collections of

| field | bits | note |
|---|---|---|
| `TransducerIndex` | 4 | contact id, 1-based |
| `Touch` | 1 | tip switch |
| `InRange` | 1 | hover |
| padding | 2 | |
| `X` | 16 | logical max **32767** |
| `Y` | 8 | logical max **127** |

then a vendor `0xff11` collection with a 64-bit field and a 32-bit field.

Total input report: **10 × 4 + 8 + 4 = 52 bytes**.

Two real reports, a tap (finger down then lift at the same place):

```
31 7b04 3f  <36 zero bytes>  2d497d5101000000  1f000000
01 7b04 3f  <36 zero bytes>  88929b5101000000  24000000
^^ ^^^^ ^^                   ^^^^^^^^^^^^^^^^  ^^^^^^^^
|  |    Y=0x3f (63, mid-height)                report counter
|  X = 0x047b little-endian
byte 0: low nibble = contact id (1)
        bits 4-5   = Touch + InRange, both set on contact, both clear on lift
                     64-bit timestamp, ns (these two differ by 1 984 347
                     for a 1.971 ms gap)
```

`X` spans 0–32767 across the 2170 px bar. `Y` was 63 in every sample observed,
which is simply mid-height — the axis is real, 0–127.

This matches `MT_CLS_APPLE_TOUCHBAR` exactly: `MT_QUIRK_HOVERING |
MT_QUIRK_TOUCH_IS_TIPSTATE | MT_QUIRK_SLOT_IS_CONTACTID_MINUS_ONE`,
`is_direct`, `maxcontacts = 11`. (Upstream says 11; the T1 descriptor declares
10. `maxcontacts` is an upper bound used when there is no `HID_DG_CONTACTMAX`
field, so the mismatch is harmless.)

Upstream's probe guard requires `HID_DG_TOUCHPAD` and
`HID_DG_TRANSDUCER_INDEX` in an input report. Both are present.

**macOS sends the digitizer nothing.** No control transfer in either capture
targets `wIndex=2`. It opens the pipe and reads. So does Linux, once
`hid-multitouch` claims it.

## 3. The DFR display (config 2, interface 3, class 0x10)

Bulk OUT `0x02`, bulk IN `0x85`. Per frame:

```
host -> device   EP 0x02   frame payload (390752 / 254672 / 144160 bytes ...)
device -> host   EP 0x85   16-byte preamble; last u32 = payload length - 16
device -> host   EP 0x85   40-byte acknowledgement containing 4c 43 44 55 (UDCL)
```

2170 × 60 px × 3 bytes = 390 600, plus headers — macOS renders every frame on
the host.

Two T1 deviations from the T2 dialect that stock `appletbdrm` does not expect:

1. **The short preamble.** Reading it as *the* response leaves the bulk pipe
   permanently one transfer out of step. The patch drains transfers shorter
   than a full response.
2. **Pipelined acknowledgement.** Frame N's response echoes frame N−1's
   timestamp. Stock treats the mismatch as fatal; the patch logs it at debug
   level.

The same desync also broke the initial `GET_INFORMATION` handshake
(`Actual size (52) doesn't match expected size (65)` → `probe failed with
error -74`), which is why the driver previously only bound after a manual USB
reconfigure.

## 4. Activation sequence

The panel stays dark even with frames streaming and the device reporting "on"
until macOS's wake sequence is replayed. From the capture, in order:

1. `bmRequestType=0x21 bRequest=0x8a wValue=0 wIndex=4 wLength=0`
2. HID SET_REPORT, Feature, Report ID 3, `wIndex=6`, 15 bytes: `03 02 f4 01 00…`
3. Standard SET_FEATURE `DEVICE_REMOTE_WAKEUP`
4. SET_INTERFACE interface 5 → alt setting 1

The sleep counterpart is SET_INTERFACE 5 → alt 0 followed by CLEAR_FEATURE
`DEVICE_REMOTE_WAKEUP`.

**Which of the four are strictly required has not been bisected.** All four are
sent together in `system/touchbar-activate`.

Panel power lives on the same 0xff12 HID interface, Feature Report ID 2
(`0xff120020` aux, `0xff120021` state):

| value written to `0x21` | result read back at `0x23` |
|---|---|
| 1 | on, 1000 |
| 2 | 150 |
| 3 | dim, 100 |
| 0 | off |

`0x20` is read-only status. Once `hid-appletb-bl` is bound this is all handled
through `/sys/class/backlight/appletb_backlight/brightness` (0–2).

## 5. The CDC-NCM link — what it actually carries

**Not** Touch Bar input. This was the prior leading hypothesis and it is wrong.

The link is IPv6 link-local over NCM: host `fe80::aede:48ff:fe00:1122`,
T1 `fe80::aede:48ff:fe33:4455`, all TCP. Four services observed:

| port | contents |
|---|---|
| 53000 | ISO 7816 / GlobalPlatform APDUs — `00 A4 04 00 0C` SELECT of AID `a0 00 00 01 51 53 50 43 41 53 44`, replies ending `90 00`. Secure Element / Apple Pay. |
| 53001 | 8-byte `{u32 cmd, u32 val}` RPC. Commands 0,1,4,5,6,7. Purpose unknown. |
| 52032 | Apple `bplist00` RPC, `92 b8 01 00` framing, service UUIDs |
| 61000/61001 | `bplist00` `GestaltKeysWithAnswers`, `EffectiveProductionStatusAp`, `UniqueChipID`, `BuildVersion` — MobileGestalt |

The decisive evidence: the capture containing **touch** has 28 URBs on EP
`0x83` and **zero NCM traffic**; the capture containing **787 NCM frames** has
**zero packets on EP `0x83`**.

## 6. Confirmed dead ends

- Interface 7 (`ff/f9/11`) is the Secure Enclave. Not display-related.
- Interface 5 alt 1 is CDC-NCM bulk data; it matters only as activation step 4.
- USB autosuspend is not the cause of a dark panel.
- The config-1 vendor `mode` command STALLs in config 2 — it does not exist there.
- `TAG-=` does not remove udev tags on udev 261.
- The `apple-ibridge` stack cannot light the panel: it forces configuration 1.
- Linux ≥ 6.3 commit `e04955db6a7c` is why `hid-sensor-hub` claims the 0xff12
  interfaces (modalias group `g0003`); relevant only to the config-1 stack.

## 7. Reproducing the evidence

USB descriptors, no root:

```bash
cat /dev/bus/usb/001/002 > descriptors.bin      # world-readable
```

Live URB capture on Linux (`scripts/diagnostics/usbmon-touch.sh` automates it):

```bash
sudo modprobe usbmon
sudo cat /sys/kernel/debug/usb/usbmon/1u | grep ':002:3'
```

macOS-side captures were taken with Wireshark on the `XHC20` interface. **See
[captures.md](captures.md) before publishing any capture** — they contain
Secure Element traffic and hardware identifiers.
