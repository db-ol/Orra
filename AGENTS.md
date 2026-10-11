# Orra engineering guide

Orra is an open source voice input app for macOS. Transcription runs on the user's Mac.
This file is the guide for anyone, human or agent, who changes this repository.

## Platform
- macOS 15.6 or later. Apple Silicon first.
- Swift 6 with strict concurrency. The project sets default actor isolation to MainActor.
- SwiftUI by default. AppKit only where SwiftUI cannot do the job (menu bar, window control, events).
- SwiftPM for approved dependencies only. docs/dependencies.md lists them. speech-swift
  (product Qwen3ASR, pinned commit) is approved for Qwen3-ASR 1.7B.
- Distributed outside the Mac App Store. App Sandbox is off because Orra will use Accessibility APIs.
- Signed by team X77KW5VYFJ. Releases use its Developer ID and are notarized. The hardened
  runtime is on, with the audio input entitlement as its only exception, which the
  microphone needs.

## Intended flow
Hotkey -> Audio Capture -> TranscriptionEngine -> optional RewriteEngine -> Text Injection

Keep it simple. Do not add a protocol, layer, or abstraction without a concrete need in the code today.

## v0.1 non-goals
No backend, no accounts, no analytics, no database, no cloud transcription, and no platforms
other than macOS. No cloud LLM rewriting. Optional rewriting on this Mac with a local model,
off by default and with the dictated text always recoverable, is allowed.

## Build discipline
Build (run in the repository root):

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Test: the same command with `-testLanguage en -testRegion US test` in place of `build`. The
tests compare English text, so they run in English whatever the Mac's language. Product >
Test in Xcode uses the Mac's language instead, unless the scheme's Test options set App
Language to English.

The build needs Xcode's Metal Toolchain component and the CudaBuild plugin of mlx-swift
trusted once in Xcode. docs/dependencies.md has the details.

- Build and test after every meaningful change. Read every warning instead of counting them.
- Never silence Swift concurrency warnings to get a green build. Fix the isolation instead.
- Never claim behavior works unless a build or a test verified it. Say what was verified and what was not.
- Orra/ and OrraTests/ are synchronized folder groups. New .swift files placed there are picked up
  automatically. Do not edit project.pbxproj by hand.

## Localization
- The interface is in English and Simplified Chinese. Orra/Localizable.xcstrings holds the
  strings, and Orra/InfoPlist.xcstrings the microphone prompt.
- SwiftUI text literals are localized on their own. Text built in code uses
  `String(localized:)`, and SwiftUI shows text that is already localized with
  `Text(verbatim:)`.
- Every new or changed string needs its Chinese translation in the catalog, marked
  translated, with full width punctuation (，。：？！（）“”) and a space between Chinese and
  a Latin word or a number. LocalizationTests checks the strings in the catalog. Xcode adds
  new strings to the catalog when it builds, a command line build does not. This lists
  every string the code uses, in build/Localizations:

      xcodebuild -exportLocalizations -project Orra.xcodeproj -scheme Orra -derivedDataPath build/DerivedData -localizationPath build/Localizations -exportLanguage zh-Hans ARCHS=arm64

## Runtime rules
- The keyboard tap runs on the main thread, so every key press on the Mac waits for it. Never
  block the main thread, and keep audio and transcription work off the main actor.
- Quit Orra before turning off or removing its Accessibility access. Revoking access while the
  tap is installed can freeze keyboard and mouse input (Apple Developer Forums thread 844416).
- Orra reads another app's text only to learn from corrections, which is off until the user
  turns it on: the field it pasted into, for 3 minutes and only while that field has the focus, never a password field or an app
  holding secure input. It stores the word pairs only, never the text, and never logs either.
- Orra goes online only for the speech model download the user starts from the menu or the
  welcome window, and for update checks through Sparkle that the user allowed or started.
  Launching must never touch the network before the user allowed update checks. Any other
  network use needs the maintainer's approval. docs/model-download.md describes the
  download, and docs/releasing.md the update feed.

## Needs maintainer approval
Do not change signing, the Development Team, the Bundle ID, entitlements, App Sandbox, or the
deployment target, and do not add a dependency or a new download server, without the
maintainer's approval. If a task needs one of these, write docs/BLOCKED.md with the question
and the options, commit it, and stop.

## Continuous integration
.github/workflows/ci.yml runs two jobs on every pull request and every push to main.
.github/workflows/pages.yml deploys the website in site/ to GitHub Pages when a push to main
changes site/. Keep the site in line with README.md, as docs/website.md describes.

- Rules check, on Linux: `python3 Tools/ci/check_rules.py`. It fails when one of the values it
  lists at the top differs: the team, bundle IDs, deployment target, App Sandbox, hardened
  runtime, entitlements and signing settings in project.pbxproj, the package references and
  linked products, and the packages and revisions in Package.resolved. It also fails on an
  .xcconfig file and when docs/dependencies.md does not name a pinned package. It covers the
  settings it lists, not every way to change signing, so review signing changes by hand too.
- Build and test, on the xcode-27 runner, a GitHub hosted Mac with Xcode 27.0. It runs the test
  command above with code signing off and plugin validation skipped, downloads the Metal Toolchain
  when the runner lacks it, and skips RealModelTests, which need the model. The wired input test
  in InputUnitTests skips itself without microphone access.
- Never run the tests from an unsigned build on a Mac where a person is logged in without that
  skip in place. Setting up an audio unit asks for microphone access, and answering the prompt
  rewrites Orra's microphone permission for the unsigned build.

Changing one of the checked values still needs the maintainer's approval first. The commit that
makes the approved change also updates the expected values in Tools/ci/check_rules.py, or the
rules check fails.

## Git
- Focused commits with clear messages. One concern per commit.
- No force push, no history rewriting, and no push unless the maintainer asks for it.
- No Xcode user state (xcuserdata) and no build output in commits. Shared schemes under
  xcshareddata are fine to track.
- No secrets, tokens, or personal data in the repository.
