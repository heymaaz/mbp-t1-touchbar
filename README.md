# Touch Bar on Linux for T1 MacBook Pros

A **lit, host-rendered, touch-responsive Touch Bar** on the 2016/2017 MacBook
Pro (MacBookPro13,x and 14,x — the **T1** chip, not T2).

Until now the T1 Touch Bar on Linux was an either/or. The `apple-ibridge`
stack gave you touch-to-keys with a **permanently dark panel**; nothing lit the
panel at all. Documentation for `appletbdrm` and `tiny-dfr` says explicitly
that they are T2-and-later only.

Both halves work now, at the same time:

- the panel lights and is driven by the host through `appletbdrm` + `tiny-dfr`
- touch works through `hid-multitouch`
- media keys by default, F1–F12 while `fn` is held
- brightness, volume, playback, keyboard backlight

Tested on a MacBookPro13,2 running Omarchy (Arch), kernel 7.1.9, LUKS2+Btrfs,
SDDM + Hyprland.

---

## Why this was thought impossible

The iBridge (`05ac:8600`) exposes three USB configurations, and no single one
contains everything:

| interface | config 1 | **config 2** | config 3 |
|---|---|---|---|
| 0,1 | UVC webcam | UVC webcam | UVC webcam |
| 2 | HID keyboard, 83-byte descriptor | **multitouch digitizer, 782-byte descriptor** | HID keyboard |
| 3 | HID 0xff12 (ALS + backlight) | **DFR display, class 0x10, 2 bulk endpoints** | HID 0xff12 |
| 4,5 | — | CDC-NCM (IP-over-USB to the T1) | CDC-NCM |
| 6 | — | HID 0xff12 (ALS + backlight) | — |
| 7 | — | vendor `ff/f9/11` (Secure Enclave) | — |

In configuration 1 the T1 firmware maps touch zones to keys itself and sends
plain HID keypresses — but there is no display interface, so the panel cannot
be lit. Configuration 2 has the display but replaces the keyboard with a raw
digitizer. A USB device has exactly one active configuration, so earlier work
concluded the two were mutually exclusive at the firmware level.

**They aren't.** Configuration 2 has everything. The digitizer was reporting
all along; nothing on Linux was listening properly.

## What was actually wrong

Three separate things, none of them a missing protocol:

1. **`hid-multitouch` didn't match the device.** Linux 6.15 added
   `MT_CLS_APPLE_TOUCHBAR` for the T2's `05ac:8302`. The T1 digitizer is the
   *same device class* on `05ac:8600`, so it fell through to `hid-generic`,
   which can't express this report format.
2. **`hid-generic` never sets `INPUT_PROP_DIRECT`**, so libinput classified the
   Touch Bar as a touchpad and emitted pointer events, not touch events.
3. **`tiny-dfr` only accepts a digitizer whose name contains `" Touch Bar"`.**
   The T1's is `"Apple Inc. iBridge Touchpad"`, so it discarded every event
   regardless.

The total fix is **four lines**: one device ID in `hid-multitouch`, one in
`appletbdrm`, one in `hid-appletb-bl`, and one name in `tiny-dfr`. Everything
else here is packaging and the reverse engineering that found them.

A prior session's leading theory was that macOS carried Touch Bar input over
the CDC-NCM link. That is **wrong**, and the captures disprove it — see
[docs/protocol.md](docs/protocol.md). The NCM link carries Apple Pay and
MobileGestalt, not input.

## Requirements

- A T1 Mac: MacBookPro13,x or 14,x (`05ac:8600` iBridge)
- **Linux ≥ 6.15** — earlier kernels have no `MT_CLS_APPLE_TOUCHBAR`
- Kernel headers, `dkms`, `python3`, `zstd`, `rust`/`cargo`, `git`
- The installer assumes Arch/pacman and Btrfs for snapshots; both are checked
  for and degrade with a warning

## Install

```bash
git clone https://github.com/Seborider/mbp-t1-touchbar
cd mbp-t1-touchbar
sudo bash scripts/install.sh
```

This snapshots first, builds and installs the DKMS modules, patches and builds
`tiny-dfr`, installs the seat rules and a pacman hook, and installs the units
**disabled**. It then brings everything up live so you can test.

Verify touch actually reaches the renderer:

```bash
python3 scripts/diagnostics/watch-endtoend.py
```

Only when that says `END TO END WORKING`, enable at boot:

```bash
sudo bash scripts/enable.sh      # re-checks the lockout canaries, refuses if unsafe
```

Then reboot once, deliberately, knowing how to reach a TTY (Ctrl+Alt+F2).

Anytime after a kernel, systemd or distro update:

```bash
bash scripts/doctor.sh
```

A healthy install reports **22 ok, 0 warnings, 0 failures**. `doctor.sh` exits
non-zero if anything fails, so it works in a cron job or an update hook. It
checks both lockout canaries (§ below) as well as the bindings, so treat any
failure as a reason not to reboot until it is understood.

To remove everything: `sudo bash scripts/uninstall.sh`.

## Read this before you enable anything at boot

Getting this wrong black-screens the machine. Two specific mistakes did, during
development:

- **Never put `AQ_DRM_DEVICES` in your Hyprland config.** A wrong value leaves
  the compositor with no GPU: `CBackend::create() failed!`, login loop.
- **Never set `ENV{ID_SEAT}` on a DRM card.** logind synthesises a seat, the
  display manager builds a D-Bus object path from the name, the hyphen is
  illegal in D-Bus paths, and SDDM crash-loops.

The working approach is `system/gen-seat-rules.sh`: shadow systemd's
`71-seat.rules` with a copy that sends the Touch Bar card to `GOTO="seat_end"`
so it gets **no seat tags at all**. `TAG-="master-of-seat"` — which upstream
`tiny-dfr`'s rule relies on — is a **no-op on udev 261**, so upstream's rule
does not work here.

`scripts/doctor.sh` checks both of these as explicit canaries, and
`scripts/enable.sh` refuses to enable if either is wrong.

## Surviving updates

| event | effect | handled by |
|---|---|---|
| `pacman -Syu` / `omarchy update` | none — every installed file is unowned by any package | — |
| kernel update | DKMS rebuilds `appletbdrm-t1` | DKMS autoinstall |
| kernel update renumbers `MT_CLS_APPLE_TOUCHBAR` | would silently bind the wrong class | `touchbar-t1-setup` reads the value out of the installed `hid-multitouch` at runtime instead of hardcoding it |
| **systemd update** | our `71-seat.rules` shadows the new stock file and silently pins the old one | pacman hook regenerates it; `doctor.sh` flags staleness by mtime |
| distro packages `tiny-dfr` | would install `/usr/bin/tiny-dfr` unpatched, alongside ours in `/usr/local/bin` | `doctor.sh` checks the running binary carries the name patch |

The last row is the real fragility: `/usr/local/bin/tiny-dfr` is a hand-built
binary. The durable fix is upstreaming — see below.

## Upstreaming

**[docs/upstreaming.md](docs/upstreaming.md) is the step-by-step guide** —
`git send-email` setup, finding maintainers with `get_maintainer.pl`, ready
commit messages, `checkpatch`, and v2 etiquette. It also tracks what has and
has not been submitted.

Everything here reduces to four one-line additions, all in `kernel/patches/`
and `userspace/`:

- `hid-multitouch`: `05ac:8600` with `MT_CLS_APPLE_TOUCHBAR`
- `appletbdrm`: `05ac:8600`, plus three T1 dialect fixes (see below)
- `hid-appletb-bl`: group-scoped `05ac:8600`
- `tiny-dfr`: accept `"Apple Inc. iBridge Touchpad"`

The `appletbdrm` T1 dialect fixes are **not** one-liners and need review before
anyone sends them upstream: the T1 prefixes each bulk reply with a short
16-byte preamble the T2 does not send, and acknowledges frames one behind. The
patch drains short transfers and downgrades the timestamp mismatch to a debug
message. Both change behaviour for T2 devices too, so they should probably be
conditional on the product ID rather than unconditional.

## Layout

```
kernel/          patched appletbdrm + hid-appletb-bl, DKMS config
kernel/patches/  unified diffs vs stock, including the hid-multitouch one-liner
userspace/       the tiny-dfr digitizer-name patch
system/          bring-up script, systemd units, seat rules generator, pacman hook
scripts/         install / enable / uninstall / doctor
scripts/diagnostics/  usbmon capture, end-to-end input check
docs/            protocol notes, report descriptor, upstreaming guide
```

## Credits

Built on work by others:

- [`appletbdrm`](https://lwn.net/Articles/986150/) and the Touch Bar DRM series
  (Kerem Karabay, Aun-Ali Zaidi, Aditya Garg), merged in Linux 6.15
- [`MT_CLS_APPLE_TOUCHBAR`](https://lwn.net/Articles/1022733/) in
  `hid-multitouch`
- [`tiny-dfr`](https://github.com/WhatAmISupposedToPutHere/tiny-dfr), by the
  Asahi Linux contributors
- [`mbp-t1-touchbar-driver`](https://github.com/parport0/mbp-t1-touchbar-driver)
  (Tschalär), the config-1 touch-to-keys stack this supersedes
- [t2linux](https://wiki.t2linux.org/)

## Licence

Kernel sources and patches: GPL-2.0, matching the files they derive from.
Scripts and documentation: MIT. See `LICENSE`.
