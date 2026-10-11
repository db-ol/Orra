# Orra

English | [简体中文](README.zh-CN.md)

Orra is an open source voice input app for the Mac. Hold a key, speak, let go, and the words land in the app you are typing in. Your speech is turned into text on your own Mac, never on a server.

Orra is an early preview. Expect rough edges, and expect the design to change.

<p align="center">
  <a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><img src="https://img.shields.io/badge/Download-Orra%20for%20macOS-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download Orra for macOS" height="40"></a><br>
  For Macs with Apple Silicon and macOS 15.6 or later
</p>

## What it does

- Dictate in Chinese, English, or both mixed in one sentence, into any app that takes text.
- Speech becomes text on your Mac with the Qwen3-ASR 1.7B model. Nothing you say leaves the Mac.
- A personal vocabulary of up to 100 names and terms, so Orra writes them your way. Optionally, Orra learns the words you fix after a dictation.
- Filler words such as 呃, um and uh are removed, and numbers spoken in Chinese, such as dates, times, prices and percentages, are written as digits.
- A small bar at the bottom of the screen shows that Orra is ready, and while you speak it shows your voice level.
- Updates install from inside the app.

## Download

Download [Orra.dmg](https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg), the newest version, open it, and drag Orra to Applications. Older versions and the release notes are on [the releases page](https://github.com/db-ol/Orra/releases).

- Needs a Mac with Apple Silicon and macOS 15.6 or later, and about 3 GB of free disk space.
- Orra is signed with a Developer ID and notarized by Apple, so it opens without a warning.
- It is not in the Mac App Store, because the App Store's sandbox does not let an app notice a key in other apps or paste into them.

## Getting started

1. Open Orra. A welcome window walks you through three steps:
   - **Download the speech model**, 2.47 GB, once.
   - **Allow the microphone.**
   - **Allow Accessibility**, which Orra needs to notice the talk key and to paste the text.
2. Hold the talk key, right Control unless you pick another, and speak. Let go, and the text appears where your cursor is.
3. Orra lives in the menu bar and the Dock. Its menu and Settings hold everything else.

## Using Orra

- **Talk key.** Choose right Control, right Option, right Command or fn (Globe) under Talk Key in the menu or in Settings, General.
- **Vocabulary.** In Settings, Vocabulary, add the words and names you use. Orra gives them to the speech model with every dictation. On test speech this raised the share of such terms written correctly from about 84% to 99% in Chinese and from 83% to 96% in English, and listed words were almost never inserted when nobody said them.
- **Learning from your corrections.** Turn on "Learn from my corrections" under Vocabulary. When you fix a misheard word right after a dictation, Orra adds the right spelling to your vocabulary and shows a notice with Undo. When you fix one Chinese character of a name, such as 陈阳 to 晨阳, Orra asks instead and offers its guess of the whole word for you to edit and add. A word you remove from the vocabulary is learned again the next time you fix it, while a word you undid is not. It works in apps that let macOS read their text, such as Notes, Mail and Safari. In other apps, copy the word and choose the add item in Orra's menu.
- **Fillers and numbers.** Before it pastes, Orra removes fillers that only fill a pause, such as 呃, 额, um and uh, and keeps words that carry meaning, such as 好啊, 吧 and 那个. It also writes numbers spoken in Chinese as digits where a reader expects them: 二零二六年十月十号 becomes 2026年10月10号, 百分之五十 becomes 50% and Lexus RX 三五零 becomes Lexus RX 350. Small counts such as 三本书, rough numbers and idioms stay in words. Settings, General turns each of them off.
- **Microphone.** Orra records from the system's default input unless you choose another under Microphone. With the lid of a MacBook closed, its own microphone is off, so choose another one, such as a webcam's.
- **Sounds, indicator, bar and Dock icon.** Settings, General turns each of them off.
- **Language.** Orra's menus and windows are in English and Simplified Chinese, following your Mac. To give Orra its own language, use System Settings, General, Language & Region, Applications.
- **Updates.** Choose Check for Updates in the menu, or let Orra check by itself under Settings, About.
- **Reporting a problem.** Choose Report a Problem… in Orra's menu and describe what happened. Continue on GitHub opens a new issue with your text, Orra's version, macOS and your Mac model filled in. GitHub needs a free account, and issues there are public. Orra also writes a diagnostic report for you to drag into the issue.

## Privacy

Orra turns your speech into text on your Mac and never sends your recordings or their text anywhere. It has no account, no analytics and no server of its own. The text it pastes stays on this Mac's clipboard, so Universal Clipboard does not offer it to your other devices.

**Learning from your corrections** is off until you turn it on. While it is on, Orra reads the text of the field it just pasted into, through macOS Accessibility, once a second for up to 3 minutes after each paste, and only while you are in that field. It reads at most 20,000 characters, keeps the text in memory during those minutes only, and never writes it anywhere. It never reads password fields or an app with secure input on. It keeps only the word pairs, such as 克劳德 and Claude, with how often and when each was seen, in ~/Library/Application Support/io.github.db-ol.Orra/corrections.json, and forgets a pair seen once after a week. Runs of three or more digits, such as codes, amounts and years, are never kept. Orra never changes the dictated text itself. Forget Learned Corrections in Settings deletes all pairs.

**Orra uses the internet for two things only.**

- **The speech model**, only after you choose Download Speech Model. It fetches six files, 2.47 GB in all, from Hugging Face (huggingface.co). If Hugging Face cannot be reached, for example from mainland China, Orra tries ModelScope (modelscope.cn) and then hf-mirror.com, which carry the same files. hf-mirror.com hands the large weights file on to Hugging Face's own servers, and outside mainland China it sends every request on to huggingface.co. Before using the files, Orra checks the size and SHA-256 hash of each against values in its source code, so a mirror cannot change the model. The files are kept in ~/Library/Application Support/io.github.db-ol.Orra/Models and left out of Time Machine backups.
- **Update checks**, only after you allow them. At its second launch Orra asks whether to check automatically, and Settings, About has the choice. A check reads https://github.com/db-ol/Orra/releases/latest/download/appcast.xml about once a day. Orra installs an update only when you choose it, each time, and only when the update and its feed are signed with the project's update key.

Launching Orra never connects to the network until you allowed update checks. Like any download, these services see your IP address, and an update check also shows Orra's version and, as every web request does, your preferred languages. Orra sends no account, token or cookie, and nothing else about your Mac.

**Report a Problem** writes a text file on your Mac with Orra's version, settings and permissions, the Mac's model, chip, memory, macOS version and languages, the microphone's name, Orra's own log from the last hour and its crash reports from the last 7 days. It holds no dictated text, audio, clipboard, vocabulary or learned words. Your home folder, account name, full name and computer name are taken out. Orra sends nothing itself. It opens the GitHub page in your browser, and the file reaches GitHub only if you attach it.

To remove the model, quit Orra and delete the Models folder above. If ~/Library/Caches/qwen3-speech holds a copy from another app, delete that too, or Orra installs the model again from it. docs/model-download.md has the details.

## Feedback and help

- **Found a problem?** Choose Report a Problem… in Orra's menu, or [open an issue on GitHub](https://github.com/db-ol/Orra/issues/new/choose). Please leave out anything private you dictated.
- **Have a question or an idea?** Ask in [Discussions](https://github.com/db-ol/Orra/discussions).

## For developers

Orra is written in Swift and SwiftUI. [docs/development.md](docs/development.md) explains how to build and test it, how the code is organized, and how releases are made. Read [AGENTS.md](AGENTS.md) before changing the code.

## License

MIT. See [LICENSE](LICENSE).
