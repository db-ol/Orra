# Releasing Orra

A release is a DMG with Orra for Apple Silicon, signed with the Developer ID of team
X77KW5VYFJ, notarized by Apple and stapled, so it opens on any Mac with macOS 15.6 or later
without a warning. `Tools/release/make-release.sh` builds it. Only the Account Holder of the
team can make the certificate, so releases are built on the maintainer's Mac.

## Setup, once per Mac

1. The certificate "Developer ID Application: Jiayao Tang (X77KW5VYFJ)" with its private
   key in the login keychain. Check with:

       security find-identity -v -p codesigning | grep "Developer ID"

   Keep an exported .p12 of it, with a password, somewhere safe outside the repository.
2. An app specific password for the Apple Account of the team, made at account.apple.com
   under Sign-In and Security, stored in the keychain as the profile `orra-notary`:

       xcrun notarytool store-credentials orra-notary --apple-id <Apple Account> --team-id X77KW5VYFJ

## Building a release

Commit everything first. The script refuses a working copy with changes, so the release
matches a commit.

    Tools/release/make-release.sh 0.1.0 1

The first argument is the version users see, the second the build number, which must grow
with every release. The script:

1. archives the Release configuration for arm64 with that version,
2. exports it with the Developer ID and checks the signature: Developer ID, hardened
   runtime, a secure timestamp, the audio input entitlement and nothing else, arm64 only,
3. notarizes the app and staples it, so it opens offline once copied out of the DMG,
4. puts it in a DMG with a link to Applications, signs the DMG, notarizes and staples it,
5. checks both with Gatekeeper and writes the DMG's SHA-256 next to it.

Output goes to build/release/<version>/, which git ignores. With `--no-notarize` as a third
argument it stops before uploading anything, to check a build quickly. Notarization can
take minutes, and for a new team its first submissions can wait hours.

## Trying a release

Run the DMG on a Mac, or a user account, that has no build from Xcode, since macOS ties
Accessibility and the microphone to the signature and the two builds sign differently.
Quit the Xcode build first otherwise. Then follow docs/manual-testing.md.
