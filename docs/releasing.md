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

## The order of a release

1. Write the release notes in all four languages and merge them on main, as the next
   section describes.
2. Build the release with make-release.sh, on main.
3. Try the DMG, as Trying a release describes.
4. Publish it, with release-notes.md from the build as the text of the GitHub release.
5. Show the new version on the website.

## Release notes

Before installing, every user reads the release notes in the update window, since Orra never
installs an update on its own. The window shows them in the language of Orra's interface,
so each language has its own file in docs/release-notes, in Markdown:

- `<version>.md` in English,
- `<version>.zh-Hans.md` in Simplified Chinese,
- `<version>.ja.md` in Japanese,
- `<version>.es-419.md` in Spanish, the Latin American Spanish of Orra's interface.

Whoever prepares the release writes the English notes and translates them into the other
three, all in one pull request, such as "Release notes for 0.5.0". The maintainer reviews
every language before it is merged. A translation names menu items and settings exactly as
Orra shows them in that language, as Orra/Localizable.xcstrings has them. Chinese uses
full width punctuation. Japanese uses 、。（） and “ ” around the names of settings, as
macOS does. Spanish uses the Latin American words of the interface, such as Configuración
and la Mac.

make-release.sh refuses to build a version after 0.4.2 while a file is missing or empty.
To check the files before that:

    python3 -I Tools/release/release_notes.py check 0.5.0 docs/release-notes/0.5.0.md

The feed has one description for each file, English first, each with the xml:lang of its
language. Sparkle picks one with `+[NSBundle preferredLocalizationsFromArray:]`, which macOS
limits to the localizations of Orra itself. So the notes come in the language the rest of
Orra shows, also when it was chosen in Orra's own settings. Someone whose languages Orra
does not have, such as French or Traditional Chinese, sees English in both. Sparkle's own
buttons follow the same rule, so the whole update window is in one language, English on a
Mac in German too. The codes are the names of Orra's localizations (en, zh-Hans, ja,
es-419) and must stay so. A new language of the interface needs its own file and an entry in
Tools/release/release_notes.py, and a test of the release scripts fails until it has them.
Until users run an Orra that has the language, they see the notes in English, as they see
the rest of Orra.

All of this holds only while Orra leaves out the Info.plist key
CFBundleAllowMixedLocalizations. That key lifts the limit, so an Orra without Japanese would
show Japanese notes and Japanese buttons on a Mac in Japanese, around an English interface.
A test of the release scripts fails if the key shows up in Orra/Info.plist or the project.

Versions up to 0.4.2 have one file with English and then Chinese. They keep it, and the
scripts treat it as before: one description without a language, and the file as it is on
the GitHub release.

The feed's Version History link opens https://github.com/db-ol/Orra/releases. Sparkle shows
it as a button in its alert that Orra is up to date, so someone who skipped versions can
read the notes of all of them there. The update window itself shows only the newest notes.

## Building a release

Merge the release notes first, and commit everything, on main. The script refuses a working
copy with changes, so the release matches a commit.

    Tools/release/make-release.sh 0.1.0 1

The first argument is the version users see, the second the build number, which must grow
with every release. The script:

1. checks the release notes in every language, before anything is built (a build with
   `--no-notarize` skips this),
2. archives the Release configuration for arm64 with that version,
3. exports it with the Developer ID and checks the signature: Developer ID, hardened
   runtime, a secure timestamp, the audio input and Apple Events entitlements and nothing
   else, arm64 only,
4. notarizes the app and staples it, so it opens offline once copied out of the DMG,
5. puts it in a DMG with a link to Applications, signs the DMG, notarizes and staples it,
6. checks both with Gatekeeper,
7. signs the DMG with the update key, writes appcast.xml with the release notes and signs it
   too, since Orra requires a signed feed,
8. writes release-notes.md, the text of the GitHub release, and then the DMG's SHA-256 next
   to the DMG,
9. copies the finished DMG to Orra.dmg, byte for byte, without building it again, and
   checks that the two files are identical, so Orra.dmg has the same SHA-256.

Output goes to build/release/<version>/, which git ignores. With `--no-notarize` as a third
argument it stops before uploading anything, to check a build quickly. Such a build gets no
Orra.dmg, and any Orra.dmg left from an earlier run is removed, so the file named for
uploading is always notarized. Notarization can
take minutes, and for a new team its first submissions can wait hours.

## Publishing

Publish a release only after trying its DMG. The tag names the version, and the feed must
be an asset of the release, since SUFeedURL reads releases/latest:

    git tag v0.1.0 "$(cat build/release/0.1.0/commit)" && git push origin v0.1.0
    gh release create v0.1.0 --title "Orra 0.1.0" \
        --notes-file build/release/0.1.0/release-notes.md \
        build/release/0.1.0/Orra-0.1.0.dmg build/release/0.1.0/Orra-0.1.0.dmg.sha256 \
        build/release/0.1.0/Orra.dmg build/release/0.1.0/appcast.xml

release-notes.md has the notes of every language under a heading in its own language
(English, 简体中文, 日本語, Español), English first. For a version up to 0.4.2 it is the notes
file as it is. To make it again without a build:

    python3 -I Tools/release/release_notes.py body 0.1.0 docs/release-notes/0.1.0.md \
        > build/release/0.1.0/release-notes.md

Every release carries the same DMG twice. Orra-<version>.dmg is the one the feed names, and
appcast.xml keeps pointing at it, so updates always fetch a file whose name says its
version. Orra.dmg is a byte identical copy for the download link in the README,
https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg, which always serves the
newest release. A release without Orra.dmg breaks that link. To add it to a release that
lacks it:

    gh release upload v0.1.0 build/release/0.1.0/Orra.dmg

Do not mark it as a pre-release: GitHub leaves pre-releases out of releases/latest, so no
installed Orra would see it. Once the release is out, every Orra that checks for updates
offers it, so a mistake reaches users within a day.

Then update the version the website shows next to the Download button, in every page of
site/, and merge it, as docs/website.md describes. The download link itself needs no change.

## Trying a release

Run the DMG on a Mac, or a user account, that has no build from Xcode, since macOS ties
Accessibility and the microphone to the signature and the two builds sign differently.
Quit the Xcode build first otherwise. Then follow docs/manual-testing.md.
