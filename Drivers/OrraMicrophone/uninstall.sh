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
    if ! rm -rf "$driver"; then
        echo "uninstall.sh: could not remove $driver" >&2
        exit 1
    fi
    echo "Removed $driver"
else
    echo "$driver is not installed"
fi

if /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null \
    || /usr/bin/killall coreaudiod 2>/dev/null; then
    echo "Restarted coreaudiod"
else
    echo "Could not restart coreaudiod. Restart the Mac to unload the driver."
fi

if /usr/sbin/pkgutil --pkg-info "$receipt" >/dev/null 2>&1; then
    /usr/sbin/pkgutil --forget "$receipt"
fi
