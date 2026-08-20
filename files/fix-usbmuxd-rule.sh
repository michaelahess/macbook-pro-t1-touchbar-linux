#!/bin/sh
# Excludes the iBridge (05ac:8600) from usbmuxd's udev rule, without disabling
# usbmuxd itself (so iPhone/iPad sync still works). Copies the shipped rule to
# /etc (which takes precedence over /lib) rather than editing the package's
# own file, so it survives package upgrades.
set -e
src=/lib/udev/rules.d/39-usbmuxd.rules
dst=/etc/udev/rules.d/39-usbmuxd.rules

if [ ! -f "$src" ]; then
	echo "no usbmuxd udev rule found at $src -- nothing to do" >&2
	exit 0
fi

sudo cp "$src" "$dst"
sudo sed -i 's#|5ac/8600/\*##' "$dst"
echo "wrote $dst excluding 05ac:8600"
