#!/bin/sh
# Removes Orra Microphone from this Mac, whether the package or a copy by hand installed it:
#
#     sudo Drivers/OrraMicrophone/uninstall.sh
#
# It deletes /Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver, restarts coreaudiod (every
# app's audio stops for a moment) and makes macOS forget the package receipt.

set -u

driver=/Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver
receipt=io.github.db-ol.Orra.Microphone.pkg

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh: run it with sudo, it removes a file from /Library" >&2
    exit 1
fi

if [ -e "$driver" ]; then
    rm -rf "$driver"
    echo "Removed $driver"
else
    echo "$driver is not installed"
fi

if ! /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
    /usr/bin/killall coreaudiod 2>/dev/null || true
fi
echo "Restarted coreaudiod"

if /usr/sbin/pkgutil --pkg-info "$receipt" >/dev/null 2>&1; then
    /usr/sbin/pkgutil --forget "$receipt"
fi
