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

## Intended flow
Hotkey -> Audio Capture -> TranscriptionEngine -> optional RewriteEngine -> Text Injection

Keep it simple. Do not add a protocol, layer, or abstraction without a concrete need in the code today.

## v0.1 non-goals
No backend, no accounts, no analytics, no database, no LLM rewriting, no cloud transcription,
and no platforms other than macOS.

## Build discipline
Build (run in the repository root):

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Test: the same command with `test` in place of `build`.

The build needs Xcode's Metal Toolchain component and the CudaBuild plugin of mlx-swift
trusted once in Xcode. docs/dependencies.md has the details.

- Build and test after every meaningful change. Read every warning instead of counting them.
- Never silence Swift concurrency warnings to get a green build. Fix the isolation instead.
- Never claim behavior works unless a build or a test verified it. Say what was verified and what was not.
- Orra/ and OrraTests/ are synchronized folder groups. New .swift files placed there are picked up
  automatically. Do not edit project.pbxproj by hand.

## Runtime rules
- The keyboard tap runs on the main thread, so every key press on the Mac waits for it. Never
  block the main thread, and keep audio and transcription work off the main actor.
- Quit Orra before turning off or removing its Accessibility access. Revoking access while the
  tap is installed can freeze keyboard and mouse input (Apple Developer Forums thread 844416).
- Orra goes online only for the speech model download the user starts from the menu.
  Launching must never touch the network. Any other network use needs the maintainer's
  approval. docs/model-download.md describes the download.

## Needs maintainer approval
Do not change signing, the Development Team, the Bundle ID, entitlements, App Sandbox, or the
deployment target, and do not add a dependency or a new download server, without the
maintainer's approval. If a task needs one of these, write docs/BLOCKED.md with the question
and the options, commit it, and stop.

## Git
- Focused commits with clear messages. One concern per commit.
- No force push, no history rewriting, and no push unless the maintainer asks for it.
- No Xcode user state (xcuserdata) and no build output in commits. Shared schemes under
  xcshareddata are fine to track.
- No secrets, tokens, or personal data in the repository.
