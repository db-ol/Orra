# Orra

English | [简体中文](README.zh-CN.md)

Orra is an open source voice input app for the Mac. Hold a key, speak, let go, and the words land in the app you are typing in. Your speech is turned into text on your own Mac, never on a server.

Orra is an early preview. Expect rough edges, and expect the design to change.

<p align="center">
  <a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><img src="https://img.shields.io/badge/-Download%20Orra%20for%20macOS-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download Orra for macOS" height="40"></a>
  <a href="https://db-ol.github.io/Orra/"><img src="https://img.shields.io/badge/-Website-555555?style=for-the-badge&logo=safari&logoColor=white" alt="Orra website" height="40"></a><br>
  For Macs with Apple Silicon and macOS 15.6 or later
</p>

## What it does

- Dictate in Chinese, English, or both mixed in one sentence, into any app that takes text.
- Speech becomes text on your Mac with the Qwen3-ASR 1.7B model. Nothing you say leaves the Mac.
- A personal vocabulary of up to 5,000 names and terms, so Orra writes them your way. Optionally, Orra learns the words you fix after a dictation.
- Filler words such as 呃, um and uh are removed, and numbers spoken in Chinese, such as dates, times, prices and percentages, are written as digits.
- Optionally, a text model on your Mac cleans up the rest: fillers the rules leave and spoken self corrections, so 三点，哦不对，四点 becomes 四点.
- Optionally, a second key pastes what you say translated between Chinese and English, with the same model on your Mac.
- A small bar at the bottom of the screen shows that Orra is ready, and while you speak it shows your voice level.
- Updates install from inside the app.

## Download

Download [Orra.dmg](https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg), the newest version, open it, and drag Orra to Applications. Older versions and the release notes are on [the releases page](https://github.com/db-ol/Orra/releases).

- Needs a Mac with Apple Silicon and macOS 15.6 or later, and about 3 GB of free disk space, plus 2.8 GB for the optional local model, which cleans up and translates.
- Orra is signed with a Developer ID and notarized by Apple, so it opens without a warning.
- It is not in the Mac App Store, because the App Store's sandbox does not let an app notice a key in other apps or paste into them.

## Getting started

1. Open Orra. A welcome window walks you through four steps. At the top, pick Orra's language, English or 简体中文, or keep the Mac's. The window switches to it right away, and you can change it later in Settings, General. The first three steps make Orra ready, and the last one is up to you:
   - **Download the speech model**, 2.47 GB, once.
   - **Allow the microphone.**
   - **Allow Accessibility**, which Orra needs to notice the talk key and to paste the text.
   - **Choose your talk key** by pressing it. On a Mac's own keyboard, fn (Globe) at the bottom left is comfortable while your right hand is on the mouse. On an external keyboard, right Control works best, because some, such as the Logitech MX Keys, never send fn.
2. Hold the talk key, right Control unless you pick another, and speak. Let go, and the text appears where your cursor is. While you speak, white bars in a small dark capsule at the bottom of the screen move with your voice (unless you turn this off in Settings), and macOS shows its orange microphone indicator in the menu bar.
3. Orra lives in the menu bar and the Dock. Its menu and Settings hold everything else.

## Using Orra

- **Talk key.** Orra listens for one talk key. In Settings, General, under Keys, click the talk key field (or Change…) and press the key you want: fn (Globe), or the left or right Control, Option or Command key. Keyboards label these keys differently, so the field shows the Mac name and symbol and, for Option and Command, what a Windows layout keyboard prints there: "⌥ Right Option (Alt)" or "⌘ Right Command (Windows key)". Talk Key in the menu shows the key and opens Settings to change it. A left Control, Option or Command key starts recording only after you hold it alone for a moment, so shortcuts such as Command C keep working. Shift, Caps Lock, letters and other keys that type cannot be the talk key, and the field says why when you press one, and which keys work. If an earlier version had several talk keys on, Orra keeps one: fn first, then right Control, then the other right hand keys, then the left hand ones.
- **Hands free.** Press the talk key twice quickly, then let go and keep talking. The indicator at the bottom of the screen says which key finishes. Press that key once to paste, or press Escape to cancel. A recording stops after 1 minute. Settings, General, under Dictation, turns double press off.
- **Vocabulary.** In Settings, Vocabulary, add the words and names you use. Orra gives them to the speech model with every dictation. On test speech this raised the share of such terms written correctly from about 84% to 99% in Chinese and from 83% to 96% in English, and listed words were almost never inserted when nobody said them. The list holds up to 5,000 words, a cap only against runaway data. Each dictation gives the model the 200 words you added or used most recently, since a longer context helps less per word and slows every dictation. Settings shows the words in a table that tells for each word whether you added it or Orra learned it, how Orra misheard it, and when you last used it.
- **Learning from your corrections.** Turn on "Learn from my corrections" in Settings, General, under Dictation. When you fix a misheard word right after a dictation, Orra adds the right spelling to your vocabulary and shows a notice with Undo. That includes taking out or putting in a space, such as read me to readme. When you fix one Chinese character of a name, such as 陈阳 to 晨阳, Orra asks instead and offers its guess of the whole word for you to edit and add. A word you remove from the vocabulary is learned again the next time you fix it, while a word you undid is not. It works in apps that let macOS read their text, such as Notes, Mail and Safari. In other apps, copy the word and choose the add item in Orra's menu.
- **Fillers and numbers.** Before it pastes, Orra removes fillers that only fill a pause, such as 呃, 额, um and uh, and keeps words that carry meaning, such as 好啊, 吧 and 那个. It also writes numbers spoken in Chinese as digits where a reader expects them: 二零二六年十月十号 becomes 2026年10月10号, 百分之五十 becomes 50% and Lexus RX 三五零 becomes Lexus RX 350. Small counts such as 三本书, rough numbers and idioms stay in words. Settings, General, Clean Up Text, Options… turns each of them off.
- **Cleanup with a local model.** Off until you turn on Clean Up Text in Settings, General. Orra then asks to download a 3.05 GB model, Qwen3.5 4B, and runs it on your Mac after the filler and number rules. It removes fillers the rules leave, such as 那个 and 就是说 used as fillers, and applies spoken self corrections, such as 三点，哦不对，四点 or "Monday, I mean Tuesday". It needs about 4 GB of memory while it is on. On an M5 Pro it added 0.6 to 1 second to a short dictation and 3 to 6 seconds to one of 400 Chinese characters, and slower Macs take longer. Dictations longer than 400 characters are pasted without cleanup. Orra holds back a cleanup that looks like an answer or a carried out request, or that adds words or numbers, and pastes the text without it, as it does when the model takes too long. These checks are heuristics, so a cleanup can still change what you meant. Paste Original Text in Orra's menu then brings back the text from before the cleanup. On hand written test dictations, 156 of 178 cleanups matched the expected text exactly, and on 70 dictations that ask the model to do something, none was carried out.
- **Translation.** Off until you turn on Translation in Settings, General, under Features. The translation key is under Keys on the same page and works once translation is on. It uses the cleanup model, also while cleanup is off, and asks to download it first when it is not on your Mac. Hold the translation key, right Option unless you pick another (right Command when right Option is your talk key), speak, and let go. Orra pastes what you said translated, Chinese into English and English into Chinese, or always into English or always into Chinese if you pick one under Translate into, right below the switch. Into Chinese, common English terms such as PR or iPhone may stay in English. The translation key waits 0.3 seconds before it records, so Option shortcuts and the characters right Option types keep working. Press it twice quickly to translate hands free. While it records, a small badge next to the bars shows 译, or EN or 中 for a fixed language. If you pick the talk key's key for the translation key, or the other way round, the two keys swap and Settings says so. Dictations over 300 characters are pasted without translation, and so is a translation that fails Orra's checks or takes too long, so nothing you say is lost. Paste Original Text brings back the text from before the translation, Copy Last Dictation copies the translation, and Orra never learns corrections from a translated paste. On an M5 Pro, with the model loaded, a short dictation took about a third of a second to translate.
- **Microphone.** Orra records from the system's default input unless you choose another under Microphone. With the lid of a MacBook closed, its own microphone is off, so choose another one, such as a webcam's.
- **Sounds, on screen hint and Dock icon.** Settings, General, under Dictation, turns the sounds off and sets the on screen hint: Always shows the bars while you dictate and a small bar while Orra is ready, Only while dictating leaves out the small bar, and Off shows neither. Show Orra in the Dock under System turns the Dock icon off.
- **Language.** Orra's menus and windows are in English and Simplified Chinese, following your Mac. To choose another, use Language in the welcome window, or Interface language in Settings, General, under System, and restart Orra. After a choice in the welcome window, Orra restarts on its own when you click Done, unless Settings or another Orra window is still open.
- **Updates.** Choose Check for Updates in the menu, or let Orra check by itself in Settings, About, which also shows the version.
- **Reporting a problem.** Choose Report a Problem… in Orra's menu and describe what happened. Continue on GitHub opens a new issue with your text, Orra's version, macOS and your Mac model filled in. GitHub needs a free account, and issues there are public. Orra also writes a diagnostic report for you to drag into the issue.

## Privacy

Orra turns your speech into text on your Mac and never sends your recordings or their text anywhere. It has no account, no analytics and no server of its own. The text it pastes stays on this Mac's clipboard, so Universal Clipboard does not offer it to your other devices.

**Learning from your corrections** is off until you turn it on. While it is on, Orra reads the text of the field it just pasted into, through macOS Accessibility, once a second for up to 3 minutes after each paste, and only while you are in that field. It reads at most 20,000 characters, keeps the text in memory during those minutes only, and never writes it anywhere. It never reads password fields or an app with secure input on. It keeps only the word pairs, such as 克劳德 and Claude, with how often and when each was seen, in ~/Library/Application Support/io.github.db-ol.Orra/corrections.json, and forgets a pair seen once after a week. Runs of three or more digits, such as codes, amounts and years, are never kept. Orra never changes the dictated text itself. Forget Learned Corrections in Settings deletes all pairs.

**Orra uses the internet for model downloads you ask for and for update checks only.**

- **The speech model**, only after you choose Download Speech Model. It fetches six files, 2.47 GB in all, from Hugging Face (huggingface.co). If Hugging Face cannot be reached, for example from mainland China, Orra tries ModelScope (modelscope.cn) and then hf-mirror.com, which carry the same files. hf-mirror.com hands the large weights file on to Hugging Face's own servers, and outside mainland China it sends every request on to huggingface.co. Before using the files, Orra checks the size and SHA-256 hash of each against values in its source code, so a mirror cannot change the model. The files are kept in ~/Library/Application Support/io.github.db-ol.Orra/Models and left out of Time Machine backups.
- **The cleanup model**, only after you turn on Clean Up Text or Translation in Settings and agree to its download. It fetches four files, 3.05 GB in all, of mlx-community/Qwen3.5-4B-4bit from the same servers in the same order, checked the same way, into its own folder under Models. The cleanup and the translation run on your Mac. No text leaves the Mac, and the model never goes online.
- **Update checks**, only after you allow them. At its second launch Orra asks whether to check automatically, and Settings, About has the choice. A check reads https://github.com/db-ol/Orra/releases/latest/download/appcast.xml about once a day. Orra installs an update only when you choose it, each time, and only when the update and its feed are signed with the project's update key.

Launching Orra never connects to the network until you allowed update checks. Like any download, these services see your IP address, and an update check also shows Orra's version and, as every web request does, your preferred languages. Orra sends no account, token or cookie, and nothing else about your Mac.

**Report a Problem** writes a text file on your Mac with Orra's version, settings and permissions, the Mac's model, chip, memory, macOS version and languages, the microphone's name, Orra's own log from the last hour and its crash reports from the last 7 days. It holds no dictated text, audio, clipboard, vocabulary or learned words. Your home folder, account name, full name and computer name are taken out. Orra sends nothing itself. It opens the GitHub page in your browser, and the file reaches GitHub only if you attach it.

To remove the models, quit Orra and delete the Models folder above. To remove only the cleanup model, turn cleanup and translation off first and delete its folder, Qwen3.5-4B-4bit-0e7ffd5c, inside it. If ~/Library/Caches/qwen3-speech holds a copy from another app, delete that too, or Orra installs the model again from it. docs/model-download.md has the details.

## Feedback and help

- **Found a problem?** Choose Report a Problem… in Orra's menu, or [open an issue on GitHub](https://github.com/db-ol/Orra/issues/new/choose). Please leave out anything private you dictated.
- **Have a question or an idea?** Ask in [Discussions](https://github.com/db-ol/Orra/discussions).

## For developers

Orra is written in Swift and SwiftUI. [docs/development.md](docs/development.md) explains how to build and test it, how the code is organized, and how releases are made. Read [AGENTS.md](AGENTS.md) before changing the code.

## License

MIT. See [LICENSE](LICENSE).
