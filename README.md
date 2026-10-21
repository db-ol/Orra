<h1 align="center">
  <a href="https://db-ol.github.io/Orra/"><img src="site/icon.png" alt="Orra" width="64" valign="middle"></a> Orra
</h1>

<p align="center">
  <a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><img src="https://img.shields.io/badge/download-Orra.dmg-0A84FF?logo=apple&logoColor=white" alt="Download Orra.dmg"></a>
  <a href="https://db-ol.github.io/Orra/"><img src="https://img.shields.io/badge/website-db--ol.github.io%2FOrra-555555?logo=safari&logoColor=white" alt="Orra website"></a>
  <a href="https://github.com/db-ol/Orra/releases"><img src="https://img.shields.io/github/v/release/db-ol/Orra?label=release&color=0A84FF" alt="Latest release"></a>
</p>

<p align="center"><sub>English · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.es.md">Español</a></sub></p>

<p align="center">
  <strong>Open source voice input for the Mac.</strong><br>
  Press a key, speak, press it again, and the words land in the app you are typing in.<br>
  Your speech is turned into text on your own Mac, never on a server.
</p>

<h3 align="center"><a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><ins>Download Orra</ins></a></h3>

<p align="center"><sub>For Macs with Apple Silicon and macOS 15.6 or later. Orra is an early preview. Expect rough edges, and expect the design to change.</sub></p>

## Features

<table>
<tr>
<td width="50%" valign="middle">

### Dictation into any app

Speak Chinese (Mandarin and Cantonese), English, or both mixed in one sentence. Under Dictation language in Settings you can pick Japanese or Spanish with English instead, as a beta. The Qwen3-ASR 1.7B model writes it down on your Mac and Orra pastes it where your cursor is. Fillers such as 呃, um and uh go away, and numbers spoken in Chinese, such as dates, prices and percentages, become digits.

</td>
<td width="50%"><img src="docs/images/readme/en/dictation.gif" alt="Holding the talk key, someone says “Um, I’ll post Wednesday’s meeting notes this afternoon.” The bars in Orra’s capsule move with the voice, and the sentence appears in a note without the um." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Your words, your spelling

A personal vocabulary of up to 5,000 names and terms, so Orra writes them your way. If you turn it on, Orra learns from the words you fix right after a dictation and writes them right the next time.

</td>
<td width="50%"><img src="docs/images/readme/en/vocabulary.gif" alt="A note says “We tested Ora on the new build.” Someone changes Ora to Orra, and Orra shows a notice: Added “Orra” to Vocabulary, Heard as “Ora”, with Undo. The next dictation writes Orra." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Cleanup with a local model

Optional. A text model on your Mac removes the fillers the rules leave and applies spoken self corrections, so “at three, oh wait, four” becomes “at four”. Paste Original Text always brings back what you said.

</td>
<td width="50%"><img src="docs/images/readme/en/cleanup.gif" alt="With Clean Up Text on, someone says “Let’s go over the quote at three, oh wait, four tomorrow.” The email gets “Let’s go over the quote at four tomorrow.”" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Translation key

Optional. Press a second key, speak, and press it again. If you set the key to Hold, keep it down while you speak instead. Orra pastes what you say translated between English and your dictation language, Chinese, Japanese or Spanish, with the same model on your Mac. A small badge shows that this dictation will be translated: 译 with Chinese, 訳 with Japanese and ⇄ with Spanish. Under Translate into you can also pick any of Chinese, English, Japanese and Spanish. The two outside your pair are a beta and go through English, which takes about twice as long.

</td>
<td width="50%"><img src="docs/images/readme/en/translation.gif" alt="In a chat, Sam asks “When can I see the designs?” Holding the translation key, someone says 我这边周五之前能把设计稿发给你. The capsule shows a 译 badge, and “I can send you the designs before Friday.” appears in the message field." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Meeting Interpretation

For meetings across languages. Read what others say in your language, and let them hear you in theirs, even in your own voice. **Live Captions** shows what the Mac plays, such as a call, as translated captions in a floating window. **Speak Translations to Others** speaks what you said with the translation key in a voice model on your Mac, into the Orra Microphone virtual device, so the other side of the call hears your words in their language.

New in 0.4.0.

</td>
<td width="50%"><img src="docs/images/readme/en/meeting.gif" alt="In a video call, Alex speaks English and the Live Captions window shows each sentence with its Chinese translation. Then the user holds the translation key and says 可以，我周三之前把测试做完, and the call hears “Sure, I’ll finish testing by Wednesday.” from Orra Microphone." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Updates inside the app

Orra checks for a new version only after you allow it, and installs one only when you choose to. Every update is signed.

</td>
<td width="50%"><img src="docs/images/readme/en/updates.gif" alt="Orra’s menu in the menu bar, with Check for Updates selected. A window offers the new version, downloads it and offers Install and Relaunch." width="100%"></td>
</tr>
</table>

## Install

- **[Download Orra.dmg](https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg)**, the newest version, open it, and drag Orra to Applications. Older versions and the release notes are on [the releases page](https://github.com/db-ol/Orra/releases).
- **Orra Microphone**, optional, for Speak Translations to Others: download [OrraMicrophone.pkg](https://github.com/db-ol/Orra/releases/download/v0.4.0/OrraMicrophone.pkg), signed and notarized, and open it to install. [Drivers/OrraMicrophone](Drivers/OrraMicrophone/README.md) explains how to remove it or build it yourself.
- Needs a Mac with Apple Silicon and macOS 15.6 or later, and about 3 GB of free disk space, plus 2.8 GB for the optional local model, which cleans up and translates, and about 2 GB for the optional voice model of Speak Translations to Others.
- Signed with a Developer ID and notarized by Apple, so it opens without a warning.
- Not in the Mac App Store, because the App Store's sandbox does not let an app notice a key in other apps or paste into them.

When you open Orra, a welcome window walks you through downloading the models, allowing the microphone and Accessibility, and choosing your talk key and how it works. The [user guide](docs/user-guide.md) explains each feature and its settings.

## Privacy

Orra turns your speech into text on your Mac and never sends your recordings or their text anywhere. It has no account, no analytics and no server of its own. It goes online only to download the models you ask for and, once you allow it, to check for updates. Features that keep anything, such as Learn from my corrections and Remember my voice, are off until you turn them on.

[docs/privacy.md](docs/privacy.md) lists what Orra keeps, when it goes online and how to remove the models.

## Community & Support

- **Report a problem.** Choose Report a Problem… in Orra's menu, or [open an issue on GitHub](https://github.com/db-ol/Orra/issues/new/choose). Please leave out anything private you dictated.
- **Questions and ideas.** Ask in [Discussions](https://github.com/db-ol/Orra/discussions).
- **WeChat.** Scan to join the Orra WeChat group.<br>
  <img src="docs/images/wechat-group.png" alt="QR code for the Orra WeChat group" width="160">
- **Show support.** If Orra is useful to you, [star it on GitHub](https://github.com/db-ol/Orra).

## For developers

Orra is written in Swift and SwiftUI. [docs/development.md](docs/development.md) explains how to build and test it, how the code is organized, and how releases are made. Read [AGENTS.md](AGENTS.md) before changing the code.

## License

MIT. See [LICENSE](LICENSE).
