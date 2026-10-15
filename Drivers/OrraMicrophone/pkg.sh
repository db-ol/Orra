#!/bin/bash
# Builds the installer package of Orra Microphone, build/OrraMicrophone.pkg. It installs
# OrraMicrophone.driver to /Library/Audio/Plug-Ins/HAL, owned by root:wheel, and restarts
# coreaudiod. From this folder:
#
#     make pkg        (or ./pkg.sh)
#
# Without any of the variables below, the package and the driver in it are signed ad hoc
# only, for a local test. This script needs no sudo, installs nothing and never reads a
# keychain on its own. Signing and notarizing happen only when the maintainer sets these:
#
#   DRIVER_IDENTITY    a "Developer ID Application" identity of team X77KW5VYFJ. Signs the
#                      driver with the hardened runtime and a secure timestamp.
#   INSTALLER_IDENTITY a "Developer ID Installer" identity of team X77KW5VYFJ. Signs the
#                      package with productsign.
#   NOTARY_PROFILE     a notarytool keychain profile. Submits the signed package, waits for
#                      the result and staples the ticket. Needs both identities above.
#
# README.md has the exact commands.
set -euo pipefail

TEAM="X77KW5VYFJ"
PKG_ID="io.github.db-ol.Orra.Microphone.pkg"

cd "$(dirname "$0")"

driver_identity="${DRIVER_IDENTITY:-}"
installer_identity="${INSTALLER_IDENTITY:-}"
notary_profile="${NOTARY_PROFILE:-}"

if [[ -n "$notary_profile" && ( -z "$driver_identity" || -z "$installer_identity" ) ]]; then
    echo "pkg.sh: NOTARY_PROFILE needs DRIVER_IDENTITY and INSTALLER_IDENTITY too" >&2
    exit 1
fi
if [[ -n "$driver_identity" && "$driver_identity" != "Developer ID Application:"*"($TEAM)" ]]; then
    echo "pkg.sh: DRIVER_IDENTITY must be a Developer ID Application identity of team $TEAM" >&2
    exit 1
fi
if [[ -n "$installer_identity" && "$installer_identity" != "Developer ID Installer:"*"($TEAM)" ]]; then
    echo "pkg.sh: INSTALLER_IDENTITY must be a Developer ID Installer identity of team $TEAM" >&2
    exit 1
fi

build="build"
bundle="$build/OrraMicrophone.driver"
work="$build/pkg"
root="$work/root"
scripts="$work/scripts"
component="$work/OrraMicrophone-component.pkg"
product="$build/OrraMicrophone.pkg"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"

# The driver is built again every time, so the package never carries a driver signed
# for another purpose.
rm -rf "$bundle" "$work" "$product"
if [[ -n "$driver_identity" ]]; then
    make --no-print-directory all SIGN_ID="$driver_identity" SIGN_FLAGS="--options runtime --timestamp"
else
    make --no-print-directory all
fi
codesign --verify --strict "$bundle"

# The payload: OrraMicrophone.driver alone, installed into /Library/Audio/Plug-Ins/HAL.
# Folders and the executable get 755, other files 644. pkgbuild records every item as
# root:wheel (its default, --ownership recommended), so building needs no sudo.
mkdir -p "$root" "$scripts"
ditto "$bundle" "$root/OrraMicrophone.driver"
chmod 755 "$root"
find "$root/OrraMicrophone.driver" -type d -exec chmod 755 {} +
find "$root/OrraMicrophone.driver" -type f -exec chmod 644 {} +
chmod 755 "$root/OrraMicrophone.driver/Contents/MacOS/OrraMicrophone"
cp Package/scripts/postinstall "$scripts/postinstall"
chmod 755 "$scripts/postinstall"

pkgbuild \
    --root "$root" \
    --component-plist Package/component.plist \
    --identifier "$PKG_ID" \
    --version "$version" \
    --install-location /Library/Audio/Plug-Ins/HAL \
    --scripts "$scripts" \
    --ownership recommended \
    "$component"

sed "s/__VERSION__/$version/" Package/Distribution.xml > "$work/Distribution.xml"
productbuild \
    --distribution "$work/Distribution.xml" \
    --package-path "$work" \
    "$product"

if [[ -n "$installer_identity" ]]; then
    productsign --sign "$installer_identity" --timestamp "$product" "$work/signed.pkg"
    mv "$work/signed.pkg" "$product"
    pkgutil --check-signature "$product"
fi

if [[ -n "$notary_profile" ]]; then
    result="$work/notary.json"
    echo "Notarizing $(basename "$product")."
    # notarytool may exit with an error for a rejected package, so its status is read from
    # the result either way, and the log fetched for anything but Accepted.
    code=0
    xcrun notarytool submit "$product" --keychain-profile "$notary_profile" --wait --timeout 12h \
        --output-format json > "$result" || code=$?
    status="$(plutil -extract status raw "$result" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "Accepted" ]]; then
        id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
        if [[ -n "$id" ]]; then
            xcrun notarytool log "$id" --keychain-profile "$notary_profile" "$work/notary-log-$id.json" || true
        fi
        echo "pkg.sh: notarization $status, notarytool exit code $code. The result and any log are in $work." >&2
        exit 1
    fi
    xcrun stapler staple "$product"
    xcrun stapler validate "$product"
fi

if [[ -n "$installer_identity" ]]; then
    signed="signed"
else
    signed="unsigned"
fi
if [[ -n "$notary_profile" ]]; then
    signed="$signed, notarized and stapled"
fi
echo "pkg.sh: $product, version $version, $signed"
