# Upstreaming the T1 Touch Bar patches

Four changes make the Touch Bar work on T1 Macs. Three go to the Linux kernel by
**email** (not GitHub); one is a normal GitHub pull request.

Do them in this order. The tiny-dfr PR is the easiest, and the most valuable
to anyone running this: it is what stops the hand-built `/usr/local/bin/tiny-dfr`
from being shadowed by a future distro package.

| # | Project | Change | Route | Difficulty |
|---|---|---|---|---|
| 1 | tiny-dfr | accept `"Apple Inc. iBridge Touchpad"` + udev rules | GitHub PR | easy |
| 2 | `hid-multitouch` | add `05ac:8600` with `MT_CLS_APPLE_TOUCHBAR` | email, linux-input | easy |
| 3 | `hid-appletb-bl` | group-scoped `05ac:8600` match | email, linux-input | easy |
| 4 | `appletbdrm` | `05ac:8600` + three T1 dialect fixes | email, dri-devel | **hard — see §6** |

---

## 0. Submission status

Nothing here has been submitted yet. Update this table as things move, so the
next person does not duplicate work:

| change | status | link |
|---|---|---|
| tiny-dfr digitizer name | not submitted | — |
| `hid-multitouch` `05ac:8600` | not submitted | — |
| `hid-appletb-bl` `05ac:8600` | not submitted | — |
| `appletbdrm` `05ac:8600` | not submitted | — |
| `appletbdrm` T1 dialect fixes | **not ready** — needs splitting, see §6 | — |

If you are picking this up, check
<https://lore.kernel.org/all/?q=05ac%3A8600> first in case someone already has.

## 1. First: the tiny-dfr pull request

Repository: <https://github.com/WhatAmISupposedToPutHere/tiny-dfr>

The patch is one line in `src/main.rs`, but a good PR should also add the T1 to
the two udev rule files so a packaged tiny-dfr works on a T1 out of the box.

```bash
cd ~/src/tiny-dfr
git remote -v                      # confirm origin is upstream
git checkout -b t1-touchbar-support
git diff                           # your main.rs change should be the only edit
```

Also edit:

- `etc/udev/rules.d/99-touchbar-seat.rules` — add
  `SUBSYSTEM=="input", ATTR{name}=="Apple Inc. iBridge Touchpad", ENV{ID_SEAT}="seat-touchbar"`
- `etc/udev/rules.d/99-touchbar-tiny-dfr.rules` — add the same name to the
  `SYSTEMD_WANTS` block, and add a config-switch line for `8600`:
  `ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8600", ATTR{bConfigurationValue}=="1", ATTR{bConfigurationValue}="0", ATTR{bConfigurationValue}="2"`

Commit message:

```
Support the Touch Bar digitizer on T1 Macs

MacBookPro13,x and 14,x expose the Touch Bar on the iBridge (05ac:8600)
rather than 05ac:8302. Bound to hid-multitouch it produces an input device
named "Apple Inc. iBridge Touchpad", which the " Touch Bar" name filter
rejects, so every touch event is discarded even though the kernel side works.

Accept that name too, and add it to the udev rules so the digitizer lands on
the seat-touchbar seat and starts the daemon.

Tested on a MacBookPro13,2 running Linux 7.1.9 with appletbdrm and
hid-appletb-bl carrying the corresponding 05ac:8600 IDs.
```

Then `git push -u origin t1-touchbar-support` and open the PR. Mention in the
description that the kernel-side patches are in flight, and link them once
they're on lore.

**Be honest in the PR that the kernel changes are not upstream yet.** A
maintainer may prefer to wait until they are, which is reasonable — say you're
happy for it to sit.

---

## 2. One-time setup for kernel patches

The kernel does not take GitHub PRs. You need `git send-email` working.

```bash
sudo pacman -S --needed git perl-authen-sasl perl-net-smtp-ssl perl-mime-tools
```

Get a kernel tree (this takes a while, and you need ~4 GB):

```bash
git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git ~/src/linux
cd ~/src/linux
```

Configure sending. For Gmail you must use an **app password**, not your normal
one — create it at <https://myaccount.google.com/apppasswords>. Substitute your
own address throughout:

```bash
git config --global sendemail.smtpserver smtp.gmail.com
git config --global sendemail.smtpserverport 587
git config --global sendemail.smtpencryption tls
git config --global sendemail.smtpuser you@example.com
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

Leave the password out of config; `send-email` will prompt.

**Critical: your mail client must not mangle whitespace.** Gmail's web interface
will destroy a patch. `git send-email` talking directly to SMTP is fine. Test
first by sending a patch **only to yourself**, then check it applies:

```bash
git send-email --to=you@example.com 0001-*.patch
# save the received mail, then:
git am /path/to/saved.eml
```

If `git am` succeeds, your setup is clean.

Read `Documentation/process/submitting-patches.rst` in the tree. It is the
authority; everything below is a summary.

---

## 3. Finding the right recipients

**Never guess addresses.** The kernel ships the answer:

```bash
cd ~/src/linux
scripts/get_maintainer.pl -f drivers/hid/hid-multitouch.c
scripts/get_maintainer.pl -f drivers/hid/hid-appletb-bl.c
scripts/get_maintainer.pl -f drivers/gpu/drm/tiny/appletbdrm.c
```

That prints maintainers, reviewers and lists with their roles. Convention:

- **To:** the maintainers
- **Cc:** reviewers, the subsystem list, `linux-kernel@vger.kernel.org`

For these files expect to see `linux-input@vger.kernel.org` for the HID drivers
and `dri-devel@lists.freedesktop.org` for `appletbdrm`. The MAINTAINERS entry
for the Touch Bar HID drivers lists **Kerem Karabay `<kerem@karabay.org.tr>>`**
covering `drivers/hid/hid-appletb-*`.

Also Cc the people who wrote the T2 support you are extending — **Aditya Garg**
and **Kerem Karabay**. `get_maintainer.pl` may surface them via git history; if
not, find their current addresses from the series on lore rather than from this
file:

<https://lore.kernel.org/all/?q=%22Touch+Bar+support+for+T2+Macs%22>

Check lore before sending anyway, to see how the T2 series was received and
whether anyone has already attempted T1 support.

---

## 4. Patch 2 — `hid-multitouch`

The strongest of the three: a single device ID reusing a class that already
exists.

```bash
cd ~/src/linux
git checkout -b t1-touchbar
```

In `drivers/hid/hid-ids.h`, next to the existing Touch Bar IDs, add if absent:

```c
#define USB_DEVICE_ID_APPLE_IBRIDGE	0x8600
```

In `drivers/hid/hid-multitouch.c`, in `mt_devices[]`, after the
`USB_DEVICE_ID_APPLE_TOUCHBAR_DISPLAY` entry:

```c
	/* Apple Touch Bar on T1 Macs (MacBookPro13,x and 14,x) */
	{ .driver_data = MT_CLS_APPLE_TOUCHBAR,
		HID_USB_DEVICE(USB_VENDOR_ID_APPLE,
			       USB_DEVICE_ID_APPLE_IBRIDGE) },
```

Commit message — the evidence matters more than the diff:

```
HID: multitouch: add device ID for the T1 Apple Touch Bar

The Touch Bar digitizer on T1 MacBook Pros (MacBookPro13,x and 14,x, the
2016 and 2017 models) is the same device class as the T2's, exposed on the
iBridge's 05ac:8600 rather than 05ac:8302.

Its report descriptor is a Digitizers/TouchPad application collection
containing ten Finger collections of

    TransducerIndex : 4 bits
    Touch           : 1 bit
    InRange         : 1 bit
    (padding)       : 2 bits
    X               : 16 bits, logical max 32767
    Y               : 8 bits,  logical max 127

followed by a vendor 0xff11 collection holding a 64-bit timestamp and a
32-bit report counter, giving a 52-byte input report with no report ID and
no HID_DG_CONTACTMAX field. That is what MT_CLS_APPLE_TOUCHBAR already
describes, so only the device ID is needed.

Note the descriptor declares ten contacts against the class's maxcontacts
of 11; since there is no HID_DG_CONTACTMAX field the class value is used as
an upper bound, so the difference is harmless.

Without this the digitizer falls back to hid-generic, which cannot express
the format and does not set INPUT_PROP_DIRECT, so userspace sees a pointer
device rather than a touchscreen.

Tested on a MacBookPro13,2 running 7.1.9: the digitizer binds to
hid-multitouch, gains INPUT_PROP_DIRECT and the ABS_MT_* axes, and tiny-dfr
drives the Touch Bar.

Signed-off-by: Your Name <you@example.com>
```

Then:

```bash
git commit -s                       # -s adds Signed-off-by
scripts/checkpatch.pl --strict -g HEAD     # must be clean
git format-patch -1 -o /tmp/patches/
git send-email --to=... --cc=... /tmp/patches/0001-*.patch
```

`checkpatch.pl` must pass. Warnings on lines you didn't touch are fine;
warnings on your own lines are not.

---

## 5. Patch 3 — `hid-appletb-bl`

Same procedure. The diff is in
`kernel/patches/hid-appletb-bl-t1.patch`.

The one thing the commit message **must** explain is why the match is
group-scoped, because it looks needlessly specific otherwise:

```
HID: appletb-bl: add support for the T1 Touch Bar backlight

T1 Macs expose the same 0xff12 usages (0xff120020 aux, 0xff120021
brightness) on the iBridge's 05ac:8600.

Match the sensor-hub HID group explicitly rather than using
HID_USB_DEVICE(). On the T1 the multitouch digitizer shares the same
vendor and product ID and differs only by HID group (g0001 vs g0003); a
vendor/product match therefore also claims the digitizer, fails to probe
it because it has no brightness fields, and leaves it with no driver and
no input device at all.

Signed-off-by: Your Name <you@example.com>
```

---

## 6. Patch 4 — `appletbdrm`: do not send this as-is

The device ID alone is fine and can go as its own patch. **The three T1 dialect
fixes should not be sent unconditionally**, and this is the one place where the
work in this repo is not yet upstream-ready.

The problem: those fixes change behaviour for **T2 devices too**.

| fix | what it does | why a maintainer will object |
|---|---|---|
| drain short bulk transfers in `appletbdrm_read_response()` | tolerates the T1's 16-byte preamble | silently swallows genuinely malformed responses on T2, up to 8 times |
| new `appletbdrm_read_fb_response()` | same, for framebuffer acks | as above |
| downgrade timestamp mismatch to `drm_dbg` | tolerates the T1 acking one frame behind | removes a real error check for every device |

Before sending, split it:

1. **Patch A:** just the `05ac:8600` ID. Trivial, likely accepted quickly.
2. **Patch B:** the dialect fixes, gated on the device — e.g. a
   `bool pipelined_ack` / `bool short_preamble` in `struct appletbdrm_device`,
   set from `driver_info` in the ID table, so T2 behaviour is byte-for-byte
   unchanged.

Lead the cover letter with the evidence, because the behaviour is surprising and
a reviewer without a T1 cannot verify it:

- the T1 precedes each bulk reply with a 16-byte preamble whose last u32 is the
  payload length minus 16
- the acknowledgement echoes the **previous** frame's timestamp
- reading the preamble as the response leaves the pipe permanently one transfer
  out of step, which is also why `GET_INFORMATION` failed at probe with
  `Actual size (52) doesn't match expected size (65)` → `-EPROTO`

`docs/protocol.md` §3 has the details; quote them in the
cover letter rather than linking, since lore readers may not follow links.

**If you would rather not do this one:** send Patch A only, and open a
[t2linux](https://github.com/t2linux) issue describing the dialect differences
with a pointer to your repo. Someone closer to that driver may pick it up. The
ID alone is still worth having upstream.

---

## 7. Multi-patch series

If you send patches 2 and 3 together (they are both `linux-input`), make it a
series with a cover letter:

```bash
git format-patch -2 --cover-letter -o /tmp/patches/
```

Edit `0000-cover-letter.patch`: replace `*** SUBJECT HERE ***` with something
like `[PATCH 0/2] HID: support the Touch Bar on T1 MacBook Pros`, and
`*** BLURB HERE ***` with the background — what a T1 is, why the T2 support
doesn't cover it, and what you tested on.

Send the whole directory in one go so threading is right:

```bash
git send-email --to=... --cc=... /tmp/patches/
```

---

## 8. After sending

- Your patch appears on <https://lore.kernel.org/linux-input/>. Link it from the
  tiny-dfr PR.
- **Expect silence for a week or two.** This is normal, not rejection. A polite
  ping after ~2 weeks is acceptable; do not resend in the meantime.
- Feedback comes as inline replies. Address every comment, then send a **v2**:
  `git format-patch -v2`, with a `---`-separated changelog under the commit
  message (below the `---` so it does not enter git history):

  ```
  Signed-off-by: ...
  ---
  v2: gate the pipelined-ack handling on the product ID (Kerem)
  ```
- Reply in-line, bottom-posting, plain text, no HTML. Do not top-post.
- When a maintainer says `Reviewed-by:` or `Acked-by:`, carry those tags into
  your next version.

## 9. Checklist before each send

- [ ] `scripts/checkpatch.pl --strict -g HEAD` clean on your lines
- [ ] the patch applies to current `mainline`/`for-next`, not just your tree
- [ ] `Signed-off-by:` present (`git commit -s`)
- [ ] recipients from `get_maintainer.pl`, not from memory
- [ ] test-sent to yourself and `git am` applies cleanly
- [ ] commit message says what you tested on and how
- [ ] one logical change per patch

## 10. A note on the patches in the repo

`kernel/patches/hid-multitouch-t1.patch` has
**reconstructed context** — it was written without a kernel checkout and says so
in its header. Regenerate all three with `git format-patch` against a real tree
before sending. Do not `git send-email` the files from the repo directly.
