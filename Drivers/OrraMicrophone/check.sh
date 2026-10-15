#!/bin/sh
# Builds Orra Microphone and checks the bundle, for a Mac with the Xcode command line tools.
# It installs nothing and needs no sudo, so CI can run it as is:
#
#     Drivers/OrraMicrophone/check.sh
#
# It fails when the driver does not compile without warnings, when Info.plist is not
# valid, when the factory that Info.plist names is not exported for both architectures,
# or when the loopback test fails.

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

echo "check.sh: OrraMicrophone.driver built and checked"
