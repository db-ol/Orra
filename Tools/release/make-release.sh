#!/bin/bash
# Builds a release of Orra: an Apple Silicon app signed with the team's Developer ID,
# notarized and stapled, in a signed, notarized and stapled DMG, and the Sparkle feed
# appcast.xml that offers the DMG to earlier versions, signed with the update key.
#
#     Tools/release/make-release.sh 0.1.0 1
#
# The arguments are the version users see and the build number, which must grow with every
# release. Output goes to build/release/<version>/. docs/releasing.md has the setup: the
# Developer ID Application certificate and the Sparkle update key in the login keychain, and
# the notarytool profile "orra-notary". The release notes come from
# docs/release-notes/<version>.md, in Markdown, and show in the update window. Pass --no-notarize as a third argument to stop before the upload, to check
# a build quickly.
set -euo pipefail

TEAM="X77KW5VYFJ"
IDENTITY="Developer ID Application: Jiayao Tang ($TEAM)"
PROFILE="orra-notary"
UPDATE_KEY_ACCOUNT="io.github.db-ol.Orra"

usage="usage: make-release.sh <version> <build> [--no-notarize]"
version="${1:?$usage}"
build="${2:?$usage}"
notarize=true
# Anything else stops here, so a mistyped flag never uploads a build meant as a check.
if [[ $# -eq 3 && "$3" == "--no-notarize" ]]; then
    notarize=false
elif [[ $# -ne 2 ]]; then
    echo "$usage" >&2
    exit 1
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "The version must look like 0.1.0" >&2; exit 1; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "The build number must be a whole number" >&2; exit 1; }

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/build/release/$version"
archive="$out/Orra.xcarchive"
export_dir="$out/export"
app="$export_dir/Orra.app"
dmg="$out/Orra-$version.dmg"
notes="$root/docs/release-notes/$version.md"
# Sparkle's tools, from the package Xcode resolves into the derived data below.
sparkle="$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

cd "$root"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working copy has changes. Commit or stash them, so the release matches a commit." >&2
    exit 1
fi
# Output goes to a variable before grep: with pipefail, grep -q ending the pipe early makes
# the writer fail with SIGPIPE, which would count as no match.
identities="$(security find-identity -v -p codesigning)"
grep -qF "$IDENTITY" <<<"$identities" || {
    echo "The certificate \"$IDENTITY\" is not in the keychain." >&2
    exit 1
}
# Installed copies of Orra accept only updates signed with the key whose public half is in
# Orra/Info.plist. A different key in this keychain would ship a feed that all of them reject.
if $notarize; then
    [[ -x "$sparkle/generate_keys" ]] || { echo "Build Orra once, so Sparkle's tools are at $sparkle" >&2; exit 1; }
    keychain_key="$("$sparkle/generate_keys" --account "$UPDATE_KEY_ACCOUNT" -p 2>/dev/null || true)"
    app_key="$(plutil -extract SUPublicEDKey raw Orra/Info.plist)"
    [[ -n "$keychain_key" && "$keychain_key" == "$app_key" ]] || {
        echo "The update key in the keychain (account $UPDATE_KEY_ACCOUNT) does not match SUPublicEDKey. docs/releasing.md says how to import it." >&2
        exit 1
    }
fi
if $notarize && [[ ! -s "$notes" ]]; then
    echo "Write the release notes in $notes first. The update window shows them." >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"
# The commit to tag when publishing.
git rev-parse HEAD > "$out/commit"
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
[[ "$(lipo -archs "$app/Contents/MacOS/Orra")" == "arm64" ]] || { echo "Not an arm64 only app" >&2; exit 1; }
# Sparkle and its helpers, signed again on export.
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$sparkle_framework" ]] || { echo "Sparkle.framework is not in the app" >&2; exit 1; }
for code in "$sparkle_framework" "$sparkle_framework/Versions/B/Autoupdate" "$sparkle_framework/Versions/B/Updater.app"; do
    signer="$(codesign -dvv "$code" 2>&1)"
    grep -qF "Authority=$IDENTITY" <<<"$signer" || { echo "$code is not signed with $IDENTITY" >&2; exit 1; }
done
shown="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"
[[ "$shown" == "$version" ]] || { echo "The app says version $shown" >&2; exit 1; }
echo "Signed: Developer ID, hardened runtime, audio input only, arm64, version $version"

submit() {
    local file="$1"
    local result="$out/notary-$(basename "$file").json"
    echo "Notarizing $(basename "$file"). A new account can wait hours for its first ones."
    # notarytool may exit with an error for a rejected build, so its status is read from
    # the result either way, and the log fetched for anything but Accepted.
    local code=0
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 12h \
        --output-format json > "$result" || code=$?
    local status id
    status="$(plutil -extract status raw "$result" 2>/dev/null || echo "unknown")"
    if [[ "$status" != "Accepted" ]]; then
        id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
        if [[ -n "$id" ]]; then
            xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$out/notary-log-$id.json" || true
        fi
        echo "Notarization: $status, notarytool exit code $code. The result and any log are in $out." >&2
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

    # The feed. Orra installs only a DMG whose signature matches its SUPublicEDKey, from a
    # feed that is signed too.
    [[ -x "$sparkle/sign_update" ]] || { echo "Sparkle's sign_update is not at $sparkle" >&2; exit 1; }
    signature="$("$sparkle/sign_update" --account "$UPDATE_KEY_ACCOUNT" -p "$dmg")"
    "$sparkle/sign_update" --account "$UPDATE_KEY_ACCOUNT" --verify "$dmg" "$signature"
    python3 -I "$root/Tools/release/appcast.py" "$version" "$build" "$dmg" "$signature" "$notes" > "$out/appcast.xml"
    "$sparkle/sign_update" --account "$UPDATE_KEY_ACCOUNT" "$out/appcast.xml"
    "$sparkle/sign_update" --account "$UPDATE_KEY_ACCOUNT" --verify "$out/appcast.xml"
    echo "Feed: $out/appcast.xml"
fi

shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "Done: $dmg"
