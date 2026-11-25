#!/bin/bash
# Installs the T1 Touch Bar driver (parport0/mbp-t1-touchbar-driver) as a DKMS
# package and applies the fixes needed for the display/touch interface to
# actually bind, on Ubuntu/Mint (Debian-based) systems. See README.md for the
# explanation of why each step exists.
#
# MAINTAINERS: the version guard below refuses Linux 7.3+ because the upstream
# driver still uses the removed struct acpi_driver API. If parport0 gains a
# 7.3+ port, drop the guard (and the README note) rather than pointing users
# elsewhere.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_REPO=https://github.com/parport0/mbp-t1-touchbar-driver.git
PKG_NAME=apple-t1-touchbar
PKG_VER=0.1
SRC_DIR="/usr/src/${PKG_NAME}-${PKG_VER}"

echo "== 0. Checking kernel version and T1 firmware state =="
IFS=. read -r KERNEL_MAJOR KERNEL_MINOR _ <<<"$(uname -r)"
KERNEL_MAJOR="${KERNEL_MAJOR:-0}"
KERNEL_MINOR="${KERNEL_MINOR:-0}"
if [ "$KERNEL_MAJOR" -ge 8 ] || { [ "$KERNEL_MAJOR" -eq 7 ] && [ "$KERNEL_MINOR" -ge 3 ]; }; then
	echo "This guide's driver does not build on Linux ${KERNEL_MAJOR}.${KERNEL_MINOR}: kernel" >&2
	echo "commit 541b293ab186 (\"ACPI: bus: Eliminate struct acpi_driver\") removed" >&2
	echo "'struct acpi_driver', which apple-ibridge.c is still built around, so the DKMS" >&2
	echo "build below would fail. As of 2026-11-25 it has not been fixed in the parport0" >&2
	echo "repo (last updated for 6.11). Use the installer that carries the" >&2
	echo "platform_driver port instead:" >&2
	echo "  https://github.com/bgausden/mbp-t1-touchbar-linux73" >&2
	exit 1
fi
if lsusb | grep -q '05ac:1281'; then
	echo "T1 chip is stuck in 'Recovery Mode' (05ac:1281). This must be fixed" >&2
	echo "before the driver can do anything -- boot a full macOS install once" >&2
	echo "(not just Recovery) and let it reach the desktop. See README.md." >&2
	exit 1
fi
if ! lsusb | grep -q '05ac:8600'; then
	echo "No Apple iBridge (05ac:8600) device found at all -- is this a T1 Mac?" >&2
	exit 1
fi
echo "iBridge healthy (05ac:8600)."

echo "== 1. Installing build dependencies =="
sudo apt-get install -y dkms build-essential "linux-headers-$(uname -r)" git

echo "== 2. Fetching driver source and packaging for DKMS =="
WORK="$(mktemp -d)"
git clone --depth 1 "$DRIVER_REPO" "$WORK/mbp-t1-touchbar-driver"
sudo mkdir -p "$SRC_DIR"
sudo cp "$WORK/mbp-t1-touchbar-driver"/{apple-ib-als.c,apple-ib-tb.c,apple-ibridge.c,Makefile} "$SRC_DIR/"
sudo cp -r "$WORK/mbp-t1-touchbar-driver/linux" "$SRC_DIR/"
sudo cp "$HERE/files/dkms.conf" "$SRC_DIR/dkms.conf"
rm -rf "$WORK"

if dkms status | grep -q "^${PKG_NAME}/${PKG_VER}"; then
	sudo dkms remove "${PKG_NAME}/${PKG_VER}" --all || true
fi
sudo dkms add -m "$PKG_NAME" -v "$PKG_VER"
sudo dkms build -m "$PKG_NAME" -v "$PKG_VER"
sudo dkms install -m "$PKG_NAME" -v "$PKG_VER"

echo "== 3. Fixing the two interfaces that steal the iBridge from this driver =="
bash "$HERE/files/fix-usbmuxd-rule.sh"

sudo cp "$HERE/files/modprobe.d/blacklist-hid-sensor-ibridge.conf" /etc/modprobe.d/
sudo update-initramfs -u

echo "== 4. Setting up boot persistence =="
sudo cp "$HERE/files/modules-load.d/apple-t1-touchbar.conf" /etc/modules-load.d/
sudo cp "$HERE/files/udev/99-apple-t1-touchbar.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules

echo
echo "Done. Reboot for everything to take effect, then check:"
echo "  lsusb -t                       # should show 4 virtual 1d6b:0301/0302 sub-devices"
echo "  dmesg | grep apple-ib-touchbar # should show it binding, not just registering"
