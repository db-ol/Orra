# Orra

Orra is an open source voice input app for macOS. The goal is simple: hold a key, speak, release, and the words land in the app you were typing in. Everything is meant to run on your own Mac.

## Status

Early stage. While you hold the talk key, right Control unless you pick another under Talk Key in the menu, Orra records. When you let go, it transcribes on your Mac with Qwen3-ASR 1.7B and pastes the text into the frontmost app. The parts pass automated tests, but Orra has not been tried in daily use yet. Expect the code and the design to change.

## Requirements

- macOS 15.6 or later. Apple Silicon is the primary target.
- Xcode 27 to build, with the Metal Toolchain component (Xcode > Settings > Components). The speech-swift dependency pulls in mlx-swift, which compiles Metal shaders at build time.
- The Qwen3-ASR 1.7B model (aufklarer/Qwen3-ASR-1.7B-MLX-8bit) in ~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit. Orra does not download it yet.
- Accessibility access, to watch the talk key and paste, and microphone access, which Orra asks for on the first hold.

## Build and test

Run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Replace `build` with `test` to run the unit tests.

The first build in Xcode asks you to Trust & Enable CudaBuild, a build tool plugin of mlx-swift. After that the command above works as is, until a package update changes mlx-swift.

## Daily use

A Release build takes about a quarter less time to transcribe than a Debug build. To keep one in ~/Applications, quit Orra, then run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
    rm -rf ~/Applications/Orra.app
    ditto build/DerivedData/Build/Products/Release/Orra.app ~/Applications/Orra.app

Open ~/Applications/Orra.app and turn on Open at Login in its menu. If macOS asks for Accessibility or microphone access again for this copy, allow it.

Orra records from the system's default input unless you choose another under Microphone in its menu or in Settings. The choice stays until you change it, and while that microphone is unplugged the default records. With the lid closed, a MacBook turns its own microphone off, so choose another one, such as a webcam's. The menu warns about it. docs/microphone-choice.md explains how the choice works.

## Contributing

Read AGENTS.md before making changes. It describes the platform choices, the intended flow, and the rules for builds and commits.

## License

MIT. See LICENSE.
