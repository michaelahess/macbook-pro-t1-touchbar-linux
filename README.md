# MacBook Pro T1 Touch Bar for Linux

Getting the physical Touch Bar (real touch input *and* the display, not just
driver binding) working on Linux, on a 2016/2017 MacBook Pro with the **T1**
security chip — as opposed to the 2018+ **T2** chip, which already has good
Linux support via [t2linux](https://wiki.t2linux.org/)/tiny-dfr and is a
completely different problem.

Confirmed working on a **MacBookPro14,3** (15", 2017, board-id
`Mac-551B86E5744E2388`), Linux Mint 22.3 (Ubuntu 24.04 base), kernel
`6.14.0-37-generic`. Should apply to any T1 MacBookPro13,x/14,x on any
Debian-based distro with only path/package-manager adjustments.

**This guide's driver does not build on Linux 7.3 and newer; use the
ported installer.** Kernel commit
[`541b293ab186`](https://github.com/torvalds/linux/commit/541b293ab186)
("ACPI: bus: Eliminate struct acpi_driver") removed `struct acpi_driver`,
which `apple-ibridge.c` — the iBridge core of the
[parport0 driver](https://github.com/parport0/mbp-t1-touchbar-driver) this
guide packages — is still built around. On 7.3+ the DKMS build fails
outright in `apple-ibridge.c`, and as of 2026-11-25 the parport0 repo
(last updated for the 6.11 era) carries no port. The fix is a port to a
`platform_driver` bound to the ACPI-created `APP7777:00` platform device,
carried in
[bgausden/mbp-t1-touchbar-linux73](https://github.com/bgausden/mbp-t1-touchbar-linux73)
— a self-contained installer that pins the same upstream driver, applies
that port on 7.3+ only, and also carries resume-path fixes that apply on
older kernels (a dropped `report_fixup`, PM forwarding that never reached
the second sub-device, and a double restore after suspend).
`install.sh` checks the running kernel up front and points you there
instead of failing halfway through the DKMS build. On kernels below
7.3, the driver source, DKMS steps, and system configuration are
unchanged.

If you already installed on an older kernel: `files/dkms.conf` sets
`AUTOINSTALL="yes"`, so after a distro upgrade to 7.3+ DKMS will try to
rebuild this package automatically and fail at boot. Move to the ported
installer above before upgrading.

## The actual bug (why every existing guide leaves the bar dark)

There is a real, existing driver for this
([parport0/mbp-t1-touchbar-driver](https://github.com/parport0/mbp-t1-touchbar-driver),
originally by Ronald Tschalär) that builds cleanly and binds without any
error in `dmesg`. And yet the Touch Bar stays completely dark, and produces
zero input events when touched. This is the actual reason:

The iBridge chip exposes the Touch Bar over **two** USB HID interfaces. One
carries the fixed function-row key emulation (Esc, F1–F12, brightness,
volume — T1 has no free-form pixel rendering; the firmware draws the strip
itself and turns touches into ordinary key events). **The other interface
carries the Touch Bar's *display*-control collection, sharing it with the
ambient light sensor.** The driver needs both to ever turn the display on.

Since **Linux 6.3**, kernel commit
[`e04955db6a7c`](https://github.com/torvalds/linux/commit/e04955db6a7c3fc4a1e6978649b61a6f5f8028e3)
("HID: Recognize sensors with application collections") — written for T2
Macs, apparently never tested against T1 — reclassifies that second
interface into `HID_GROUP_SENSOR_HUB`. The generic `hid-sensor-hub` driver
now matches it first and claims it before `apple-ibridge` ever gets a
chance to probe it. The result: the driver binds "successfully," but the
half of it that would ever turn the display on has nothing to attach to.
It's a silent failure — no error anywhere, the module just never gets the
device it needs.

You can see this directly on an affected system:

```
$ readlink /sys/bus/hid/devices/0003:05AC:8600.000*/driver
../../../../../../../bus/hid/drivers/apple-ibridge-hid   # interface 1 - fine
../../../../../../../bus/hid/drivers/hid-sensor-hub       # interface 2 - stolen
```

This repo exists because, as far as we could find researching this, nobody
has written down that this is the cause or how to fix it — every guide for
this driver just describes the (necessary but insufficient) build/DKMS/
usbmuxd steps and stops there.

## What "working" means here, honestly

This gets you the same thing macOS shows 95% of the time: the
firmware-drawn strip with real touch — Esc, Fn row, brightness, keyboard
backlight, media/volume, and dimming/idle behavior. **Arbitrary custom
graphics on the Touch Bar are a different, harder problem** that (as far as
we found) nobody has solved on Linux for T1 specifically — see
[Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux), which
has tracked this as "missing" since 2019.

## Quick start

```bash
git clone <this repo>
cd macbook-pro-t1-touchbar-linux
./install.sh
sudo reboot
```

Or do it by hand — see [`install.sh`](install.sh), it's short and every step
is echoed. The pieces, in order:

1. **Confirm the T1 firmware is actually initialized**: `lsusb` must show
   `05ac:8600 Apple, Inc. iBridge`, not `05ac:1281 ... Recovery Mode`. If
   it's stuck in recovery mode, nothing below will do anything until you fix
   that — boot a full macOS install once (not just Recovery — reaching the
   Recovery picker and shutting down again is *not* sufficient, we verified
   this the hard way) and let it reach the desktop, then shut down properly.
2. Install `dkms build-essential linux-headers-$(uname -r) git`.
3. Clone the driver and package it for DKMS — it doesn't ship a
   `dkms.conf`, so we provide one ([`files/dkms.conf`](files/dkms.conf)).
4. Exclude the iBridge from `usbmuxd`'s udev rule
   ([`files/fix-usbmuxd-rule.sh`](files/fix-usbmuxd-rule.sh)) — a
   separately-known conflict; without this, `usbmuxd` (used for iPhone/iPad
   sync) grabs the device first. This alone does *not* fix the dark
   display — that's step 5.
5. **The actual fix**: blacklist `hid_sensor_hub`, `hid_sensor_als`,
   `hid_sensor_trigger`, `hid_sensor_iio_common`
   ([`files/modprobe.d/blacklist-hid-sensor-ibridge.conf`](files/modprobe.d/blacklist-hid-sensor-ibridge.conf))
   and rebuild the initramfs.
6. Set up boot persistence: load the modules automatically
   ([`files/modules-load.d/apple-t1-touchbar.conf`](files/modules-load.d/apple-t1-touchbar.conf))
   and run the documented USB unbind/probe workaround automatically via udev
   ([`files/udev/99-apple-t1-touchbar.rules`](files/udev/99-apple-t1-touchbar.rules))
   — without this, the generic `usb` driver grabs the device before
   `apple-ibridge` can.
7. Reboot.

## Verifying it actually worked

```bash
lsusb -t
```
Should show **four** virtual sub-devices (`1d6b:0301` ×2, `1d6b:0302` ×2) —
two from each of the iBridge's two real interfaces. If you only see two,
something is still stealing the second interface.

```bash
dmesg | grep apple-ib-touchbar
```
Should show it binding to devices on *both* underlying interfaces, and
ideally a `tb: Touchbar deactivated` (or similar state-machine) message —
proof it reached the actual mode-management code, not just registration.

## Optional: keep the display always on

By default the bar turns off after 5 minutes idle (same as macOS) and back
on with any input. To force it always on:

```bash
find /sys/devices -iname idle_timeout   # path includes a per-boot instance number
echo -1 | sudo tee <path-from-above>
```

**We have not verified a clean way to make this persist across reboots** —
the module parameter is read-only after load (`0444`), and the sysfs path
changes each boot, so a naive udev rule is nontrivial to get right. If you
solve this cleanly, a PR would be very welcome.

## Other things we tried, for the record

- **[roadrunner2/macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver)**
  (`touchbar-driver-hid-driver` branch) — the actual original upstream
  project. Needed patching for several kernel-API breaks (`iio_device_alloc`
  signature, `platform_driver.remove`/`acpi_driver.remove` now returning
  `void`, `acpi_driver` losing its `.owner` field, `hid_driver.report_fixup`
  return type) to even build on 6.14. After patching, it builds and loads,
  but its internal HID-sub-device dispatch never actually spawned working
  sub-devices for us even after applying the same interface fix above — the
  parport0 fork above is the more complete implementation in practice.
- We deliberately **did not use** a third fork,
  `F13-Kr1pt0n/macbook-pro-touchbar-driver` — not because its claims were
  false (some, e.g. mainline `hid-appletb-kbd`/`hid-appletb-bl`/`appletbdrm`
  existing, turned out to be true, just T2-only and irrelevant here), but
  because its README referenced a `touchbar-reset.service` file that
  doesn't exist in the repo, and the repo had a single commit despite
  claiming an elaborate multi-year, multi-author history. Untrusted content
  asking you to build and load kernel code is worth being careful about
  regardless of outcome. Skim it yourself before using it.
- The iBridge exposes 3 USB configurations (`bNumConfigurations=3`); every
  known driver, including this one, only ever uses config 1. Windows'
  [imbushuo/DFRDisplayKm](https://github.com/imbushuo/DFRDisplayKm)
  documents config 2 as a full-framebuffer "DFR display" mode and claims
  (untested, per its own README) T1 support. Nobody has gotten this working
  on Linux as far as we found. Switching configs would also take out the
  FaceTime camera and every existing driver — treat as a research project,
  not a fix, and don't attempt it as a first move.

## Credits

- [Ronald Tschalär (roadrunner2)](https://github.com/roadrunner2) — original
  T1 iBridge/Touch Bar Linux driver work.
- [parport0](https://github.com/parport0) — the build-updated fork this
  guide packages.
- [Barry Gausden (bgausden)](https://github.com/bgausden) — the Linux 7.3+
  `platform_driver` port of the driver and the resume-path fixes, packaged
  in [bgausden/mbp-t1-touchbar-linux73](https://github.com/bgausden/mbp-t1-touchbar-linux73).
- Everyone in
  [Dunedan/mbp-2016-linux#189](https://github.com/Dunedan/mbp-2016-linux/issues/189)
  and [t2linux/kernel#12](https://github.com/t2linux/kernel/issues/12) who
  bisected and discussed the underlying `HID_GROUP_SENSOR_HUB` regression —
  this repo connects that discussion to a concrete fix, it didn't discover
  the regression itself.

## License

The files in this repo (this README, `install.sh`, the udev/modprobe/dkms
config snippets) are original and licensed MIT — see [LICENSE](LICENSE).
This repo does not vendor the driver's C source; `install.sh` clones it
fresh from upstream, which is GPL-2.0 licensed.
