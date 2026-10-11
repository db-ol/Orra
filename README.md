# Orra

Orra is an open source voice input app for macOS. It sits in the menu bar and the Dock, and Settings can take it out of the Dock. The goal is simple: hold a key, speak, release, and the words land in the app you were typing in. Everything is meant to run on your own Mac.

## Status

Early stage. While you hold the talk key, right Control unless you pick another under Talk Key in the menu, Orra records. When you let go, it transcribes on your Mac with Qwen3-ASR 1.7B and pastes the text into the frontmost app. In between, a small bar at the bottom of the screen shows that Orra is ready, which Settings can turn off. The parts pass automated tests, but Orra has not been tried in daily use yet. Expect the code and the design to change.

## Requirements

- macOS 15.6 or later. Apple Silicon is the primary target.
- Xcode 27 to build, with the Metal Toolchain component (Xcode > Settings > Components). The speech-swift dependency pulls in mlx-swift, which compiles Metal shaders at build time.
- About 3 GB of free disk space for the speech model, Qwen3-ASR 1.7B (aufklarer/Qwen3-ASR-1.7B-MLX-8bit). Orra downloads it, 2.47 GB, when you choose Download Speech Model in its menu or in the welcome window. If ~/Library/Caches/qwen3-speech already holds it, Orra reuses that copy without downloading.
- Accessibility access, to watch the talk key and paste, and microphone access. At launch, until Orra has its model and both permissions, a welcome window walks you through the download and the two permissions.

## Download

Download the DMG from [the latest release](https://github.com/db-ol/Orra/releases/latest), open it, and drag Orra to Applications. It is signed with a Developer ID and notarized by Apple, and runs on Apple Silicon Macs with macOS 15.6 or later. Orra asks for the microphone and for Accessibility, which it needs to notice the talk key and paste the text. Later versions install from inside the app.

## Build and test

Run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Replace `build` with `-testLanguage en -testRegion US test` to run the unit tests. They compare English text, so they run in English.

The first build in Xcode asks you to Trust & Enable CudaBuild, a build tool plugin of mlx-swift. After that the command above works as is, until a package update changes mlx-swift.

## Daily use

A Release build takes about a quarter less time to transcribe than a Debug build. To keep one in ~/Applications, quit Orra, then run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
    rm -rf ~/Applications/Orra.app
    ditto build/DerivedData/Build/Products/Release/Orra.app ~/Applications/Orra.app

Open ~/Applications/Orra.app and turn on Open at Login in its menu. If the welcome window opens for this copy, grant what it lists.

Orra's menu and windows are in English and Simplified Chinese, in the order of your preferred languages in System Settings > General > Language & Region. You can give Orra its own language there under Applications.

While Orra listens, a small indicator at the bottom of the screen shows bars that move with your voice, and a short sound marks the start and the end of the recording. When a dictation pastes nothing, the indicator says why. Both can be turned off in Settings.

Before it pastes, Orra removes filler words that never carry meaning: 呃, 额, um, uh and erm, 嗯 unless it is an answer or comes before a reply such as 嗯，好的, and 啊 or 哦 that opens a clause before a comma, unless a correction such as 不是 follows. A filler in quotation marks stays. Words that can mean something, such as 好啊, 吧, 呢, 那个 and like, stay as you said them. Self corrections such as "三点，哦不是四点" are not applied. Settings, General turns filler removal off.

Orra also writes numbers that the speech model spelled out in Chinese as digits, only where a reader clearly expects digits: 二零二六年十月十号 becomes 2026年10月10号, 下午三点半 becomes 下午3点半, 百分之五十 becomes 50%, 三百五十块 becomes 350块, 四十二公里 becomes 42公里 and Lexus RX 三五零 becomes Lexus RX 350. Small counts such as 三本书, numbers before a counter such as 二十个人, rough numbers such as 十几个, ordinals such as 第三, and idioms such as 一心一意 and 三五成群 stay in words. Settings, General turns this off too.

In Settings, the Vocabulary page takes the words and names you use, up to 100. Orra gives them to the speech model with every dictation, so it writes them your way. On synthetic test speech this raised the share of such terms written correctly from about 84% to 99% in Chinese and from 83% to 96% in English, and words from the list were almost never inserted when they were not said. The list stays on your Mac.

Orra records from the system's default input unless you choose another under Microphone in its menu or in Settings. The choice stays until you change it, and while that microphone is unplugged the default records. With the lid closed, a MacBook turns its own microphone off, so choose another one, such as a webcam's. The menu warns about it. docs/microphone-choice.md explains how the choice works.

## Privacy

Orra turns your speech into text on your Mac and never sends your recordings or their text anywhere. The text it pastes stays on this Mac's clipboard, so Universal Clipboard does not offer it to your other devices. Orra has no account, no analytics and no server of its own.

Learning from your corrections is off until you turn it on under Vocabulary in Settings. While it is on, Orra reads the text of the field it pasted into, through macOS Accessibility, once a second for up to 3 minutes after each paste, following each of the last five pastes, so you can dictate several lines and fix them afterwards, to see whether you fixed a misheard word. While you are in another app or field, it waits and reads nothing. It reads only that field, up to 20,000 characters, keeps the text in memory during those minutes only, and never writes it anywhere. It never reads password fields or an app with secure input on. It keeps only the word pairs, such as 克劳德 and Claude, with how often and when each was seen, in ~/Library/Application Support/io.github.db-ol.Orra/corrections.json, and forgets a pair seen once after a week. Runs of three or more digits, such as codes, amounts and years, are never kept, while names such as Qwen3 are. The first time you fix a misheard word, Orra adds the right spelling to your vocabulary and shows a notice with Undo for 10 seconds, longer while the pointer is over it. It never changes the dictated text itself, the vocabulary only helps the model hear the word. Undo takes the word back, and Orra does not learn it again. A learned word you remove from the vocabulary is not added again either. Forget Learned Corrections deletes all pairs and keeps the vocabulary. Learning works only in apps that let macOS read their text, such as Notes, Mail and Safari, not in some editors and terminals. In any app, copy a word and the Orra menu offers to add it to your vocabulary. A fix of a single Chinese character is not learned, since it is too often grammar. Add such words to the vocabulary yourself.

Orra uses the internet for two things: downloading its speech model, only after you choose Download Speech Model in the menu or the welcome window, and checking for updates, only after you allow it. Launching Orra never connects to the network until you allowed update checks. At its second launch Orra asks whether to check automatically, and the choice is under About in Settings. A check reads https://github.com/db-ol/Orra/releases/latest/download/appcast.xml about once a day. GitHub sees your IP address, Orra's version and, as with any web request, your preferred languages, and nothing else about your Mac. Check for Updates in the menu checks at any time. Orra installs an update only when you choose it, each time, and only when the feed and the DMG are signed with the project's update key. The download fetches six files, 2.47 GB in all, from Hugging Face (huggingface.co). If Hugging Face cannot be reached, for example from mainland China, Orra tries ModelScope (modelscope.cn) and then hf-mirror.com, which carry the same files. hf-mirror.com hands the large weights file on to Hugging Face's own download servers, and outside mainland China it sends every request on to huggingface.co. Like any download, these services and the networks they hand the files to see your IP address. Orra sends no account, token or cookie.

Before using the files, Orra checks the size and SHA-256 hash of each one against values written in its source code, so a mirror cannot change the model. The files are kept in ~/Library/Application Support/io.github.db-ol.Orra/Models and left out of Time Machine backups. To remove the model, quit Orra and delete that folder. If ~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit or ~/Library/Caches/qwen3-speech/aufklarer_Qwen3-ASR-1.7B-MLX-8bit exists, delete it as well. While it exists, Orra installs the model again from it at its next launch, and Orra's copy shares disk space with it. docs/model-download.md has the details.

## Contributing

Read AGENTS.md before making changes. It describes the platform choices, the intended flow, and the rules for builds and commits.

## License

MIT. See LICENSE.
