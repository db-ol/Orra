# Releasing Orra

A release is a DMG with Orra for Apple Silicon, signed with the Developer ID of team
X77KW5VYFJ, notarized by Apple and stapled, so it opens on any Mac with macOS 15.6 or later
without a warning, and appcast.xml, the Sparkle feed that offers it to earlier versions.
`Tools/release/make-release.sh` builds both. Only the Account Holder of the
team can make the certificate, so releases are built on the maintainer's Mac.

## Setup, once per Mac

1. The certificate "Developer ID Application: Jiayao Tang (X77KW5VYFJ)" with its private
   key in the login keychain. Check with:

       security find-identity -v -p codesigning | grep "Developer ID"

   Keep an exported .p12 of it, with a password, somewhere safe outside the repository.
2. An app specific password for the Apple Account of the team, made at account.apple.com
   under Sign-In and Security, stored in the keychain as the profile `orra-notary`:

       xcrun notarytool store-credentials orra-notary --apple-id <Apple Account> --team-id X77KW5VYFJ

3. The Sparkle update key, an EdDSA key pair. The private key is in the login keychain under
   the account `io.github.db-ol.Orra`, and its public key is SUPublicEDKey in
   Orra/Info.plist. Every installed Orra accepts only updates signed with it, so a lost key
   means no more updates for anyone. Keep an export of it somewhere safe outside the
   repository. Sparkle's tools come with the package, after a build:

       build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account io.github.db-ol.Orra -p
       build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account io.github.db-ol.Orra -x <file>

   The first prints the public key, the second exports the private one. On a new Mac,
   `generate_keys --account io.github.db-ol.Orra -f <file>` imports it.

## Building a release

Write the release notes in docs/release-notes/<version>.md, in Markdown, in English and
Chinese. The update window shows them. Commit everything, on main. The script refuses a
working copy with changes, so the release matches a commit.

    Tools/release/make-release.sh 0.1.0 1

The first argument is the version users see, the second the build number, which must grow
with every release. The script:

1. archives the Release configuration for arm64 with that version,
2. exports it with the Developer ID and checks the signature: Developer ID, hardened
   runtime, a secure timestamp, the audio input entitlement and nothing else, arm64 only,
3. notarizes the app and staples it, so it opens offline once copied out of the DMG,
4. puts it in a DMG with a link to Applications, signs the DMG, notarizes and staples it,
5. checks both with Gatekeeper,
6. signs the DMG with the update key, writes appcast.xml with the release notes and signs it
   too, since Orra requires a signed feed, and writes the DMG's SHA-256 next to it.

Output goes to build/release/<version>/, which git ignores. With `--no-notarize` as a third
argument it stops before uploading anything, to check a build quickly. Notarization can
take minutes, and for a new team its first submissions can wait hours.

## Publishing

Publish a release only after trying its DMG. The tag names the version, and the feed must
be an asset of the release, since SUFeedURL reads releases/latest:

    git tag v0.1.0 "$(cat build/release/0.1.0/commit)" && git push origin v0.1.0
    gh release create v0.1.0 --title "Orra 0.1.0" --notes-file docs/release-notes/0.1.0.md \
        build/release/0.1.0/Orra-0.1.0.dmg build/release/0.1.0/Orra-0.1.0.dmg.sha256 \
        build/release/0.1.0/appcast.xml

Do not mark it as a pre-release: GitHub leaves pre-releases out of releases/latest, so no
installed Orra would see it. Once the release is out, every Orra that checks for updates
offers it, so a mistake reaches users within a day.

## Trying a release

Run the DMG on a Mac, or a user account, that has no build from Xcode, since macOS ties
Accessibility and the microphone to the signature and the two builds sign differently.
Quit the Xcode build first otherwise. Then follow docs/manual-testing.md.
