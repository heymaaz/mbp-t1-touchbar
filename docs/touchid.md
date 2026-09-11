# Touch ID on the T1

**Short answer: Touch ID is reachable on Linux, this machine has the one
irreplaceable prerequisite, and this repository will not implement it.** The
working implementation is [t1bridge](https://github.com/standardagents/t1bridge).
This document records how the sensor is actually reached, why reimplementing it
here would be disproportionate, and the one route that plausibly gets Touch ID
working *without* giving up the Touch Bar stack in this repo.

Everything below is derived from t1bridge at commit `f148acd` (packaged version
`0.1.7`) and from this machine. Anything not actually run is marked
**UNVERIFIED**.

---

## 1. How the sensor is reached

The fingerprint sensor is **not a separate USB interface**, and there is no HID
device for it. Capture and matching happen inside the T1's Secure Enclave; the
host only drives the conversation. Two channels are involved, and both already
exist on a machine running this repo's stack:

| Channel | What it is | State on this machine |
|---|---|---|
| Interface 7 of configuration 2 | The Secure Enclave. Vendor class `ff/f9/11`, bulk OUT `0x05`, bulk IN `0x88`. Driven from userspace over `usbfs`; no kernel driver binds it | Present and **unbound** — `/sys/bus/usb/devices/1-3:2.7`, class `ff f9 11`, no driver link |
| The CDC-NCM link | `BridgeXPC` frames and Apple `Mesa` biometric messages, TCP over IPv6 link-local to the T1, port **52032**. xART anti-replay records come back inbound on TCP **61500** | Interfaces 4/5 exist in configuration 2; no driver bound, because this repo does not ship an NCM driver |

`docs/protocol.md` §5 in this repo independently identified port 52032 as
"Apple `bplist00` RPC, `92 b8 01 00` framing, service UUIDs" from a macOS
capture, and §6 files interface 7 as a confirmed dead end *for the display work*.
Both findings are correct; they are also exactly the two channels Touch ID uses.

Sources in t1bridge: `sep-probe/sep_usbfs.h` (interface and endpoint constants),
`crates/t1-bridge/src/transport.rs` (BridgeXPC framing),
`crates/t1-bridge/src/mesa.rs` (biometric message types),
`docs/architecture.md` §"Boot and ordering contract".

## 2. The prerequisite, and why it is the whole ballgame

Touch ID needs **this specific Mac's** `EFI/APPLE/EMBEDDEDOS/FDRData`. It is
machine-bound: another Mac's copy will not work, re-enrolling fingerprints will
not regenerate it, and reinstalling anything will not recreate it. If the Apple
EFI partition was erased during a Linux install, the only recovery is restoring
macOS and letting it complete a first boot — which can erase the Linux install.

**On this machine it is present:**

```
$ sudo ls -l /boot/EFI/APPLE/EMBEDDEDOS/FDRData
-rwx------ 1 root root 209892 Aug 26 02:52
```

There is one ESP (`nvme0n1p1`, mounted at `/boot`) plus a surviving 85.3G Apple
APFS partition at `nvme0n1p3`. **Back that file up to another device now**, before
any partitioning, reinstall, or disk experiment. Nothing else in this document
matters if it is lost.

## 3. Why this repository will not implement it

This repo's thesis is that the T1 Touch Bar needs four one-line additions to
existing upstream software. Touch ID is not that shape. A from-scratch
implementation here would need: a CDC-NCM shim, BridgeXPC framing, Apple binary
plist parsing, the SEP keybag/keystore/ACM protocol, Mesa biometric sequencing,
xART anti-replay storage, machine-data import with DER/IMG4 validation, paired
"catacomb" persistence, and a libfprint driver. In t1bridge that is on the order
of 40,000 lines of protocol work against no specification.

Reimplementing it would not produce a better result than the implementation that
already exists. So: **use t1bridge for Touch ID.** The rest of this document is
about doing that without losing the Touch Bar.

## 4. What breaks if you just install t1bridge on top of this stack

Installing `t1bridge` + `t1bridge-dkms` alongside this repo collides in four
places. Each one individually is enough to leave the Touch Bar dark or the
desktop broken.

| Collision | Why |
|---|---|
| **Two `appletbdrm` modules** | `t1bridge-dkms` installs its own `appletbdrm` into `/updates/dkms`, the same precedence path this repo's DKMS package uses. Which one wins is a coin flip |
| **Two config-selection mechanisms** | `t1_cfgsel` picks configuration 2 during enumeration, from initramfs. This repo's `touchbar-t1-setup` registers `05ac:8600` with `hid-multitouch` *before* switching configuration, specifically so `hid-generic` loses the probe race. If the configuration is already switched at initramfs time, that window is gone and **touch stops working** |
| **The seat udev rule** | `99-zz-t1bridge-touchbar.rules` sets `ENV{ID_SEAT}` on the Touch Bar DRM card and tries to drop `master-of-seat` with `TAG-=`. This repo's README documents `ID_SEAT` on a DRM card as having crash-looped the display manager, and `TAG-=` is a **no-op on udev 261**, which is what this machine runs. It is installed by the *userspace* package, so you get it even without the DKMS one |
| **Two Touch Bar renderers** | `t1-touchbar-hw.service` claims the DRM card, hidraw digitizer and uinput; the system preset enables it automatically. It will fight `tiny-dfr` |

There is also a softer cost: `libfprint-t1bridge` and `fprintd-t1bridge`
*replace* the distribution's `libfprint` and `fprintd` system-wide, for every
consumer on the machine, not just the Touch Bar.

## 5. The hybrid: this repo's Touch Bar, t1bridge's Touch ID

Four facts, each checked in t1bridge's sources, together make this look viable:

1. **The userspace package does not depend on the DKMS package.**
   `packaging/arch/t1bridge/PKGBUILD` declares
   `depends=('gcc-libs' 'glibc' 'iio-sensor-proxy' 'systemd>=256')` — no
   `t1bridge-dkms`. So the kernel half can be skipped.
2. **`apple_t1_ncm` builds standalone.** 57 lines, its own trivial Makefile
   (`obj-m += apple_t1_ncm.o`), no reference to the other three modules. The NCM
   link can be had without `t1_cfgsel`, without their `appletbdrm`, and without
   their vendored `uvcvideo`.
3. **The Touch ID chain has no dependency on the Touch Bar services.**
   `t1-ncm-ready@` binds only to the net device; `t1-xart-storage@` to the net
   device plus `t1-ncm-ready@`; `t1bridge-keybag` is gated on a state file;
   `t1-touchid-auth` on its sockets plus the keybag. None of them reference
   `t1-touchbar-hw`. The Touch Bar half is cleanly separable.
4. **t1bridge does not care who selected configuration 2.**
   `crates/t1-import/src/status.rs` reads `bConfigurationValue` and compares it
   to `2`; its own tests treat `2` as `selected` and `1` as `unexpected`. It does
   not check that `t1bridge-cfgselector` is the bound driver. This repo's
   `touchbar-t1-setup` already puts the device on configuration 2, which
   satisfies that check.

So the shape of the hybrid is:

- **Keep:** this repo's `appletbdrm`, `hid-appletb-bl`, `hid-multitouch`
  registration, `touchbar-t1-setup`, `tiny-dfr`, `touchbar-t1-appmap`, seat rules.
- **Add:** `apple_t1_ncm` only, built from t1bridge's `kernel/apple-t1-ncm/`.
- **Add:** the `t1bridge` userspace package, with its Touch Bar half disabled.
- **Add:** `libfprint-t1bridge` and `fprintd-t1bridge` for `fprintd`/PAM.
- **Skip entirely:** `t1bridge-dkms` (`t1_cfgsel`, their `appletbdrm`, `uvcvideo`).

### Neutralising the two things that would still bite

Both are required, not optional:

```bash
# 1. Stop t1bridge's Touch Bar half from ever starting. Do this BEFORE
#    installing the package, so its preset cannot enable it.
sudo systemctl mask t1-touchbar-hw.service t1-touchbar-hw.socket
systemctl --user mask t1-touchbar.service

# 2. Shadow its seat rule with an empty file of the same name. A file in
#    /etc/udev/rules.d wins over the one in /usr/lib/udev/rules.d.
sudo touch /etc/udev/rules.d/99-zz-t1bridge-touchbar.rules
sudo udevadm control --reload-rules
```

Then `bash scripts/doctor.sh` must still report a clean run — in particular the
two lockout canaries (exactly one logind seat; the `appletbdrm` card not
`master-of-seat` while the i915 card keeps it) and the digitizer still bound to
`hid-multitouch`. **If `doctor.sh` is not clean, stop and undo before rebooting.**

### Remaining steps, in order

1. Back up `FDRData` to another device.
2. Snapshot the system (`btrfs subvolume snapshot -r /`).
3. Mask the units and shadow the udev rule, as above.
4. Build and install `apple_t1_ncm` only.
5. Install `t1bridge`, `libfprint-t1bridge`, `fprintd-t1bridge`.
6. Import machine data from `FDRData` with the packaged CLI.
7. Allow inbound IPv6 TCP **61500**, scoped to the T1 NCM interface only —
   never globally.
8. `sudo t1bridge status`, then enroll and verify with `fprintd-enroll` /
   `fprintd-verify`.

Consult t1bridge's own `docs/setup.md` for the exact commands in steps 4–8; they
are versioned with the package and will outlast this document.

## 6. UNVERIFIED

**The hybrid in §5 has never been run.** It is assembled from reading t1bridge's
sources, not from a working system. Specifically unverified:

- Whether the t1bridge userspace services actually come up with only
  `apple_t1_ncm` present and no `t1_cfgsel`. The four facts in §5 say the
  dependencies permit it; nothing proves the code paths tolerate it.
- Whether `t1bridge validate usb-cycle` and `usb-live-loss` function at all.
  Almost certainly not: `docs/architecture.md` states "the configuration-selector
  driver is the sole unbind/rebind target", and in this hybrid that driver is
  absent. Expect the recovery tooling to be unavailable, and expect a full
  power cycle to be the only recovery from a wedged SEP.
- Whether replacing the distribution `libfprint`/`fprintd` disturbs anything else
  on an Omarchy system.
- Whether masking `t1-touchbar-hw` causes any Touch ID path to fail — the unit
  dependency graph says no, but the Touch ID overlay is documented as publishing
  cosmetic state through it, so enrollment prompts may simply not appear on the
  Touch Bar. That is cosmetic, not functional. Unconfirmed.
- Whether the T1 tolerates this repo's userspace activation sequence and
  t1bridge's SEP session concurrently. Both touch the device over `usbfs`.

Resolving all of these means trying it, on a snapshot, with a TTY escape route.

## 7. If the hybrid fails

The fallback is a deliberate full switch to t1bridge: uninstall this stack with
`scripts/uninstall.sh`, then install `t1bridge` + `t1bridge-dkms` normally. That
trades away real things — twelve working media keycodes become Esc and F1–F12
unless you supply a desktop-provider executable, and the Hyprland-aware layouts
in this repo have no equivalent — in exchange for Touch ID, the camera, and a
packaged install. It is a supported configuration; the hybrid is not.

## 8. See also

- `docs/protocol.md` §5 and §6 — the NCM services and interface 7, from captures
- `../COMPARISON-t1bridge.md` §5 — the full feasibility analysis this came from
- [t1bridge](https://github.com/standardagents/t1bridge) — `docs/setup.md`,
  `docs/architecture.md`, `docs/touch-id.md`
