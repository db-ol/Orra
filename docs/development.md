# Developing Orra

This guide is for people who build, test or change Orra. [AGENTS.md](../AGENTS.md) has the rules every change follows, and the README describes Orra for its users.

## Requirements

- A Mac with Apple Silicon and macOS 15.6 or later.
- Xcode 27, with the Metal Toolchain component (Xcode > Settings > Components). The speech-swift dependency pulls in mlx-swift, which compiles Metal shaders at build time.
- The first build in Xcode asks you to Trust & Enable CudaBuild, a build tool plugin of mlx-swift. After that the command line builds work as they are, until a package update changes mlx-swift.

## Build and test

Run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Replace `build` with `-testLanguage en -testRegion US test` to run the unit tests. They compare English text, so they run in English whatever the Mac's language. docs/manual-testing.md lists what the tests cover and the checks to make by hand.

A build from Xcode and a release from GitHub are signed differently, and macOS ties Accessibility and the microphone to the signature. Quit one before running the other, and grant access again when Orra asks.

## A faster build for daily use

A Release build transcribes about a quarter faster than a Debug build. To keep one in ~/Applications, quit Orra, then run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
    rm -rf ~/Applications/Orra.app
    ditto build/DerivedData/Build/Products/Release/Orra.app ~/Applications/Orra.app

## How the code is organized

Orra is one app target, Orra/, with its unit tests in OrraTests/. The flow is: talk key (HotkeyTap, TalkKeyDetector) → recording (AudioRecorder, InputUnit) → transcription (Qwen3Engine, Transcription) → paste (TextInserter), driven by PushToTalkController and its state machine. Around it are the model download (ModelDownload, ModelInstaller), the feedback while dictating (RecordingFeedback, RecordingIndicator), the vocabulary and learning from corrections (Vocabulary, Corrections, CorrectionLearning, LearnedNotice), updates (AppUpdater) and the interface (StatusMenu, SettingsView, WelcomeView).

The interface is in English and Simplified Chinese. AGENTS.md explains how to add or change a string.

## Background documents

- [dependencies.md](dependencies.md): the approved packages and why.
- [model-download.md](model-download.md): where the speech model comes from and how it is checked.
- [asr-options.md](asr-options.md), [asr-baseline.md](asr-baseline.md), [local-asr-models.md](local-asr-models.md): how the speech model was chosen and measured.
- [hotkey-options.md](hotkey-options.md), [microphone-choice.md](microphone-choice.md): design notes.
- [releasing.md](releasing.md): signing, notarization, updates and publishing.
- [manual-testing.md](manual-testing.md): what the tests cover and what to check by hand.

## Contributing

Open an issue or a pull request on GitHub. Pull requests are squash merged, so the title and the description should explain the whole change. Continuous integration runs the rules check and the tests on every pull request.
