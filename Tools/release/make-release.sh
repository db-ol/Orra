#!/bin/bash
# Builds a release of Orra: an Apple Silicon app signed with the team's Developer ID,
# notarized and stapled, in a signed, notarized and stapled DMG.
#
#     Tools/release/make-release.sh 0.1.0 1
#
# The arguments are the version users see and the build number, which must grow with every
# release. Output goes to build/release/<version>/. docs/releasing.md has the setup: the
# Developer ID Application certificate in the login keychain and the notarytool profile
# "orra-notary". Pass --no-notarize as a third argument to stop before the upload, to check
# a build quickly.
set -euo pipefail

TEAM="X77KW5VYFJ"
IDENTITY="Developer ID Application: Jiayao Tang ($TEAM)"
PROFILE="orra-notary"

version="${1:?usage: make-release.sh <version> <build> [--no-notarize]}"
build="${2:?usage: make-release.sh <version> <build> [--no-notarize]}"
notarize=true
[[ "${3:-}" == "--no-notarize" ]] && notarize=false
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "The version must look like 0.1.0" >&2; exit 1; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "The build number must be a whole number" >&2; exit 1; }

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/build/release/$version"
archive="$out/Orra.xcarchive"
export_dir="$out/export"
app="$export_dir/Orra.app"
dmg="$out/Orra-$version.dmg"

cd "$root"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working copy has changes. Commit or stash them, so the release matches a commit." >&2
    exit 1
fi
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
    echo "The certificate \"$IDENTITY\" is not in the keychain." >&2
    exit 1
}

rm -rf "$out"
mkdir -p "$out"
echo "Building Orra $version ($build) from $(git rev-parse --short HEAD)"

xcodebuild archive \
    -project Orra.xcodeproj -scheme Orra -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    -derivedDataPath "$root/build/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    > "$out/archive.log" 2>&1 || { tail -30 "$out/archive.log"; exit 1; }

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
    -exportOptionsPlist "$out/ExportOptions.plist" \
    > "$out/export.log" 2>&1 || { tail -30 "$out/export.log"; exit 1; }

# The checks a user's Mac makes, before anything is uploaded.
codesign --verify --deep --strict "$app"
details="$(codesign -dvv "$app" 2>&1)"
grep -q "Authority=$IDENTITY" <<<"$details" || { echo "Not signed with $IDENTITY" >&2; exit 1; }
grep -q "flags=.*runtime" <<<"$details" || { echo "The hardened runtime is off" >&2; exit 1; }
grep -q "Timestamp=" <<<"$details" || { echo "The signature has no secure timestamp" >&2; exit 1; }
entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - -)"
[[ "$entitlements" == '{"com.apple.security.device.audio-input":true}' ]] || {
    echo "Unexpected entitlements: $entitlements" >&2
    exit 1
}
lipo -archs "$app/Contents/MacOS/Orra" | grep -qx "arm64" || { echo "Not an arm64 only app" >&2; exit 1; }
shown="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"
[[ "$shown" == "$version" ]] || { echo "The app says version $shown" >&2; exit 1; }
echo "Signed: Developer ID, hardened runtime, audio input only, arm64, version $version"

submit() {
    local file="$1"
    echo "Notarizing $(basename "$file"). A new account can wait hours for its first ones."
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 12h \
        --output-format json > "$out/notary-$(basename "$file").json"
    local status
    status="$(plutil -extract status raw "$out/notary-$(basename "$file").json")"
    if [[ "$status" != "Accepted" ]]; then
        local id
        id="$(plutil -extract id raw "$out/notary-$(basename "$file").json")"
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$out/notary-log-$id.json" || true
        echo "Notarization: $status. The log is in $out." >&2
        exit 1
    fi
}

# The app gets its own ticket first, so it opens without a network connection after it was
# copied out of the DMG.
if $notarize; then
    ditto -c -k --keepParent "$app" "$out/Orra.zip"
    submit "$out/Orra.zip"
    xcrun stapler staple "$app"
    rm "$out/Orra.zip"
fi

staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Orra.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Orra $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" > /dev/null
rm -rf "$staging"
codesign --sign "$IDENTITY" --timestamp "$dmg"

if $notarize; then
    submit "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    spctl --assess --type execute -v "$app"
fi

shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "Done: $dmg"
