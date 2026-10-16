#!/bin/sh
# Builds Orra Microphone and checks the bundle, for a Mac with the Xcode command line tools.
# It installs nothing and needs no sudo, so CI can run it as is:
#
#     Drivers/OrraMicrophone/check.sh
#
# It fails when the driver does not compile without warnings, when Info.plist is not
# valid, when the factory that Info.plist names is not exported for both architectures,
# when the loopback test fails, or when the unsigned installer package (pkg.sh) does not
# hold the driver as expected.

set -eu

cd "$(dirname "$0")"

make --no-print-directory all

bundle=build/OrraMicrophone.driver
executable="$bundle/Contents/MacOS/OrraMicrophone"
factory=$(/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories' Info.plist | sed -n 's/.* = //p')

plutil -lint Info.plist "$bundle/Contents/Info.plist"

if [ "$factory" != "OrraMicrophone_Create" ]; then
    echo "check.sh: Info.plist names the factory '$factory', expected OrraMicrophone_Create" >&2
    exit 1
fi

for arch in arm64 x86_64; do
    if ! nm -arch "$arch" -gU "$executable" | grep -q " T _$factory\$"; then
        echo "check.sh: $arch slice does not export _$factory" >&2
        exit 1
    fi
    exported=$(nm -arch "$arch" -gU "$executable" | grep -c " T " || true)
    if [ "$exported" -ne 1 ]; then
        echo "check.sh: $arch slice exports $exported functions, expected only the factory" >&2
        nm -arch "$arch" -gU "$executable" >&2
        exit 1
    fi
done

lipo -info "$executable"
codesign --verify --strict "$bundle"

make --no-print-directory test

# The installer package, unsigned. Signing variables from the caller's environment are
# dropped, so this never signs or notarizes.
env -u DRIVER_IDENTITY -u INSTALLER_IDENTITY -u NOTARY_PROFILE ./pkg.sh

fail() {
    echo "check.sh: $*" >&2
    exit 1
}

pkg=build/OrraMicrophone.pkg
expanded=build/pkg/expanded
rm -rf "$expanded"
pkgutil --expand "$pkg" "$expanded"
component="$expanded/OrraMicrophone-component.pkg"

# Payload: the driver bundle and nothing else, every item root:wheel, folders and the
# executable 755, other files 644. Entries starting with ._ carry extended attributes
# such as com.apple.provenance, which the installer restores as attributes, not files.
bom=$(lsbom -p fMUG "$component/Bom" | grep -v '/\._' | awk '{ print $1, $2, $3, $4 }' | sort)
expected=$(sort <<'EOF'
. drwxr-xr-x root wheel
./OrraMicrophone.driver drwxr-xr-x root wheel
./OrraMicrophone.driver/Contents drwxr-xr-x root wheel
./OrraMicrophone.driver/Contents/Info.plist -rw-r--r-- root wheel
./OrraMicrophone.driver/Contents/MacOS drwxr-xr-x root wheel
./OrraMicrophone.driver/Contents/MacOS/OrraMicrophone -rwxr-xr-x root wheel
./OrraMicrophone.driver/Contents/_CodeSignature drwxr-xr-x root wheel
./OrraMicrophone.driver/Contents/_CodeSignature/CodeResources -rw-r--r-- root wheel
EOF
)
if [ "$bom" != "$expected" ]; then
    echo "check.sh: the package payload differs from the expected one:" >&2
    echo "$bom" >&2
    exit 1
fi

grep -q 'install-location="/Library/Audio/Plug-Ins/HAL"' "$component/PackageInfo" \
    || fail "the package does not install to /Library/Audio/Plug-Ins/HAL"
grep -q 'relocatable="false"' "$component/PackageInfo" || fail "the driver is relocatable"
grep -q 'identifier="io.github.db-ol.Orra.Microphone.pkg"' "$component/PackageInfo" \
    || fail "the package identifier is wrong"
grep -q '<os-version min="15.6"/>' "$expanded/Distribution" || fail "the minimum macOS is not 15.6"
grep -q 'hostArchitectures="arm64,x86_64"' "$expanded/Distribution" \
    || fail "the package does not allow arm64 and x86_64"
[ -x "$component/Scripts/postinstall" ] || fail "postinstall is missing or not executable"
cmp -s Package/scripts/postinstall "$component/Scripts/postinstall" || fail "postinstall differs"
grep -q 'kickstart -k system/com.apple.audio.coreaudiod' "$component/Scripts/postinstall" \
    || fail "postinstall does not restart coreaudiod"
sh -n "$component/Scripts/postinstall"

# The driver as the installer unpacks it still has a valid signature.
rm -rf build/pkg/full
pkgutil --expand-full "$pkg" build/pkg/full
codesign --verify --strict build/pkg/full/OrraMicrophone-component.pkg/Payload/OrraMicrophone.driver
sh -n uninstall.sh

echo "check.sh: OrraMicrophone.driver and OrraMicrophone.pkg built and checked"
