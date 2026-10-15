# Meeting interpretation, phases 2 and 3

Written on 2026-10-14. Plan only, no code. Nothing was installed, no model was downloaded
and nothing was recorded for it.

Phase 1, built separately, listens to the other side of a call (system audio) and shows
what they say, translated, in a floating window on the user's Mac. This note plans the
two directions that are left:

- **Phase 2:** the user's own speech, translated, reaches the other side as text.
- **Phase 3:** the other side hears the translation spoken in the user's own voice,
  through a microphone that Orra provides.

Facts carry a source number from the list at the end. "Measured by others" means a
number from a project's own benchmark, not from this Mac. "Unverified" means I found no
source I trust for it. Facts about Orra come from this repository at 32e8b95.

Context that applies to everything below:

- Orra targets macOS 15.6, is not sandboxed, uses the hardened runtime, and ships signed
  and notarized with Developer ID outside the App Store.
- Orra already has the pieces for one direction of speech: the microphone, Qwen3-ASR
  1.7B through speech-swift, the translation key with Qwen3.5 4B, and a paste through
  Accessibility. On an M5 Pro the speech model took 128 to 282 ms per request
  (docs/local-asr-models.md) and a short translation took about a third of a second
  (README).
- Orra's rules: no text or audio from a dictation is logged or saved, everything runs on
  the Mac, and any new package, Info.plist key, entitlement or project change needs the
  maintainer.

## Summary

| | Effort | New permission or key | Driver or extension | Other side sees or hears |
|---|---|---|---|---|
| 2a. Paste into the meeting chat with the translation key | 1 to 2 days | none, uses Accessibility | no | a chat message |
| 2b. A caption window the user shares | 3 to 5 days | none for Orra | no | captions, only while the user shares that window |
| 2c. A virtual camera with captions over the video | 4 to 6 weeks | system extension entitlement, camera usage text | camera extension | captions on the user's video |
| 3a. Speak into a loopback device the user installed (BlackHole and similar) | 1 to 2 weeks | none for Orra | user's own | the translation, spoken |
| 3b. Speak into the shared screen's computer sound | 1 week | none for Orra | no | the translation, only while sharing |
| 3c. Orra's own virtual microphone | 6 to 10 weeks with the voice work | installer with admin password | Audio Server plug in | the translation, spoken |

The recommendation is at the end: 2a first, then 2b, then 3a as a test bed for the voice
pipeline, and 3c only after the maintainer decides on a driver.

## Phase 2: the user's speech as text

The user speaks in their language, Orra translates it, and the other side reads it. The
translation step is the same in every option: the translation key's pipeline that ships
today. The options differ in how the text reaches the other side.

### 2a. Paste into the meeting chat

The user clicks into the meeting app's chat field, holds the translation key, speaks and
lets go. Orra pastes the translation. This works today in Zoom, Teams, Meet in a browser,
Slack huddles and anything else with a text field, because the translation key already
pastes into the focused field.

What phase 2 would add:

- An optional "send after paste" in meeting mode, which presses Return after the paste so
  the message goes out. Off by default, because a bad translation then cannot be fixed
  before it is sent. A translation with a line break would be sent in pieces, so Orra
  would join lines before it sends.
- Showing the translated line in the phase 1 window as well, marked as the user's own, so
  the conversation reads in one place.
- Optionally the original under the translation in the same message ("原文：…"), so a
  bilingual reader can check it. A setting.

Effort: 1 to 2 days. Permissions: none new. Accessibility is already granted for the
paste. Privacy: the text goes into the meeting's chat, which the meeting service stores
like any chat message. That is the user's choice per message. The other side sees a chat
line, which is easy to miss while someone talks, and the chat panel must be open.

### 2b. A caption window the user shares

A second floating window shows the user's own translated lines in large type. The user
shares that window (or the whole screen) in the meeting app, and the other side reads it
as part of the shared screen.

- Zoom, Teams and Meet can share a single window, so the user can keep the rest of the
  screen private. Meet in Chrome shares a window or a screen [21].
- The caption window must be capturable. AppKit windows can opt out of screen capture
  with `NSWindow.sharingType = .none`. If the phase 1 window does that to keep the other
  side's captions private, this window must not. Two windows with different settings is
  the clean answer: the private one for the other side's words, a shareable one for the
  user's.
- Speech input: push to talk with the translation key (as in 2a, but the result goes to
  the window instead of the paste), or continuous listening with a voice activity
  detector. Continuous listening means the microphone stays on for the whole meeting,
  the orange dot stays on, and every word the user says is transcribed, including side
  remarks. Push to talk is the better first version. Continuous listening is a
  maintainer decision, see the end.
- Captions live in memory only and are dropped when the window closes, like phase 1.

Effort: 3 to 5 days if phase 1's window and caption model can be reused. Permissions:
none new for Orra. The meeting app needs Screen Recording, which users who share their
screen have already granted. The other side sees captions only while the user shares,
which often conflicts with sharing slides. Sharing the caption window and slides at once
works only in apps that share several windows (unverified per app).

### 2c. A virtual camera with captions over the video

Orra provides a camera, "Orra Camera", that shows the user's real camera with the
translated captions drawn at the bottom. The user picks it as the camera in the meeting
app. The other side sees subtitles on the user's video, which is the most natural result.

- macOS 12.3 and later do this with a Core Media I/O camera extension, a system extension
  bundled inside the app. Legacy DAL plug ins are deprecated [12][13].
- The app needs the `com.apple.developer.system-extension.install` entitlement, a new
  extension target in the project, an `NSCameraUsageDescription` because the extension
  reads the real camera, and the app must run from /Applications. The user approves the
  extension once in System Settings, Login Items & Extensions [12][13].
- Reported problems: the camera can be missing in a meeting app until that app is
  restarted, and OBS's virtual camera did not appear in Zoom 5.16.2 on macOS 14.1 in one
  report [13]. Each meeting app needs its own test.
- The extension runs as its own process, so the captions must reach it from Orra over
  IPC (a Core Media sink stream, as Apple's sample does, or XPC). Unverified how much of
  Apple's sample can be reused.

Effort: 4 to 6 weeks, most of it in the extension, the installer flow and testing in
three meeting apps. It changes the project file, signing and entitlements, so the
maintainer has to do those parts in Xcode. The other side sees captions all the time, in
any layout, with no screen share.

### Other options looked at

- **The meeting app's own captions or translation.** Zoom, Teams and Meet offer
  translated captions on some plans (plans and languages unverified), and Teams has an interpreter that can simulate the speaker's voice
  in nine languages, Mandarin among them, with the speaker's consent [18][19]. When the
  other side already has them, Orra adds little. Orra's value is that it works in any app,
  on the Mac, without the meeting's paid plan.
- **Typing the translation as keystrokes** instead of a paste. No gain over the paste, and
  slower.
- **Sending text through the meeting app's API or a bot.** Needs per app accounts and
  network access. Against Orra's local rule.

## Phase 3: the user's voice in the other language

Pipeline: the user speaks, Orra detects the end of the sentence, transcribes, translates,
synthesizes the translation in the user's voice, and plays it into a microphone that the
meeting app listens to. Four parts: the microphone device, the voice model, the timing,
and the safeguards.

### The virtual microphone

macOS has no public way for an app to create an input device that other apps can pick,
except through an audio driver.

**Audio Server plug in (recommended if Orra ships its own).** A bundle in
/Library/Audio/Plug-Ins/HAL that coreaudiod loads. It adds a device, for example "Orra
Voice", with an output side and an input side wired together (a loopback). Orra plays the
synthesized speech into the output side, and the meeting app records from the input side.
BlackHole and Background Music work this way [1][2][3].

- **Install:** copy the bundle to /Library/Audio/Plug-Ins/HAL, which needs an
  administrator password, then restart coreaudiod (`sudo killall -9 coreaudiod`) or
  reboot [1]. Removing it needs the same. Orra today installs by drag and drop with no
  password, so this is a new kind of install: a separate signed and notarized .pkg, or an
  "Install Orra Voice" button that runs a privileged helper. BlackHole ships a script that
  builds, signs and notarizes its installer package [1]. Notarizing a .pkg needs a
  Developer ID Installer certificate (unverified whether the team has one).
- **No Apple entitlement is needed** for an Audio Server plug in. AudioDriverKit is not
  an option: Apple does not grant its entitlement for virtual devices and points to the
  Audio Server plug in model instead [14][15].
- **Restarting coreaudiod** cuts all audio on the Mac for a moment, including a running
  call. The installer must say so. Whether macOS 15 and 26 pick up a new plug in without
  a restart is unverified.
- **Licenses of the starting points:**

| Base | License | Notes |
|---|---|---|
| BlackHole [1] | GPL 3.0, commercial license on request | A driver derived from it is GPL 3. Orra is MIT. The driver is a separate program that talks to Orra only through Core Audio, so Orra itself can stay MIT, but the driver's source must be published under GPL 3. BlackHole's README says "A license is required for all non-GPLv3 projects". Needs the maintainer's decision, and legal advice if in doubt. |
| Background Music [2] | GPL 2.0 or later | Same as above. Larger, includes app volume control that Orra does not need. |
| libASPL [3] | MIT | C++17 library for Audio Server plug ins. Small project (89 stars, last push 2025-08). Compatible with Orra's MIT license. |
| Apple's "Creating an Audio Server Driver Plug-in" sample (NullAudio) [4] | MIT style (LICENSE.txt in the download, "Copyright © 2024 Apple Inc.", read on 2026-10-14) | Plain C, one device, 44.1 and 48 kHz, two channels of 32 bit float. Needs a loopback ring buffer added. |

  The sample or libASPL keeps everything MIT. A loopback device is a few hundred lines
  on top of either. Effort for a minimal "Orra Voice" device with an installer and an
  uninstaller: 2 to 4 weeks, most of it in the installer, notarization and testing.

**Routing the user's real voice.** Once the meeting app listens to "Orra Voice", it no
longer hears the real microphone. Three ways to handle that:

1. Translation only: the other side hears only the synthesized voice. Simple, but a
   sentence Orra misses is lost, and there is silence while the user speaks.
2. Mix: Orra captures the real microphone all the time and plays it into "Orra Voice",
   quieter while a translation plays (as Teams lets listeners turn the original down
   [18]). The other side hears the original, then the translation. Needs continuous
   microphone capture and adds a few tens of ms to the user's normal voice (unverified,
   to be measured).
3. Switch: Orra passes the real microphone through until the user holds the translation
   key, and plays only the translation during that time.

Option 3 fits Orra's push to talk design and is the recommended first version.

**Alternatives without a driver:**

- **A loopback device the user installs (3a).** The user installs BlackHole or Rogue
  Amoeba's Loopback themselves. Orra adds an output device picker "Speak translation
  into", saved by device UID like the microphone choice (docs/microphone-choice.md),
  and plays into it through an output AUHAL. Orra distributes no driver, so no license
  question for Orra. Good for testing the voice pipeline with real meetings before
  building a driver, but setup is too hard for most users.
- **Share computer sound (3b).** Zoom's "Share sound" and Meet's "Also share system
  audio" send the Mac's output to the meeting while the user shares a screen or window
  [20][21]. Orra plays the translation to the default output. The user hears it too,
  and it works only while sharing. Zoom installs its own ZoomAudioDevice for this.
- **Playing through the speakers into the microphone.** Works anywhere, sounds poor, and
  the meeting app's echo cancellation may remove it. Not recommended.
- **Aggregate devices and process taps** cannot inject audio into another app's input.
  A process tap reads output, which is what phase 1 uses.

### Voice models that can run on the Mac

The voice must speak the translation in the user's voice, usually across languages: the
user speaks Chinese and the voice speaks English, or the other way round. So the model
must clone a voice from a short sample and speak both Chinese and English with it.

speech-swift, which Orra already links for Qwen3-ASR, ships several of these as separate
products: `Qwen3TTS`, `CosyVoiceTTS`, `F5TTS`, `ChatterboxTTS`, `KokoroTTS`,
`FishAudioTTS` and more [5]. They are already in the commit Orra pins (1f54e56, read on
2026-10-14) [6]. Linking one more product of an approved package is still a dependency
change for the maintainer, but adds no new package. mlx-audio (Python) and
mlx-audio-swift (MIT) also run Qwen3-TTS and Fish Audio S2 Pro on MLX [16][17].

| Model | Weights license | Commercial use | Size | Chinese and English | MLX or Core ML | Clone sample | First audio on an M series Mac | Quality |
|---|---|---|---|---|---|---|---|---|
| Qwen3-TTS 12Hz 0.6B Base [7][8] | Apache 2.0 | yes | 0.6B, 0.96 GB at 8 bit, 1.7B variant 3.5 GB at 8 bit | both, 10 languages | MLX and Core ML in speech-swift | "3 second voice cloning" upstream. speech-swift implements the speaker vector mode, the higher quality in context mode is planned | about 120 ms (1 frame) to 225 ms (3 frames) on an M2 Max, without cloning, measured by others | round trip WER 9.74% for 0.6B and 3.66% for 1.7B at 8 bit, measured by others |
| Fun-CosyVoice 3 0.5B [9][10] | Apache 2.0 | yes | 0.5B, 1.4 to 2.1 GB in MLX | both, 9 languages and 18 Chinese dialects, cross lingual cloning stated | MLX in speech-swift | not stated upstream (unverified, 3 to 10 s is common) | "as low as 150 ms" upstream on a GPU. Not measured on a Mac (unverified) | upstream CER 1.21% Chinese, WER 2.24% English, speaker similarity 78% and 72% |
| CosyVoice 2 0.5B [11] | Apache 2.0 | yes | 0.5B | both | through the CosyVoice 3 runtime (unverified) | as above | unverified | below CosyVoice 3 upstream |
| F5-TTS v1 [22][23] | CC BY NC 4.0 (code MIT) | **no** | 336M, 0.8 GB | both | MLX in speech-swift and f5-tts-mlx | short clip plus its transcript | not streaming. RTF 0.57 on an M5 Pro, so about 3 s for 5 s of speech, measured by others | one word substituted in a round trip test, measured by others |
| Chatterbox Multilingual [24] | MIT | yes | 0.8B, about 1.3 GB | both, 23 languages | MLX in speech-swift | zero shot from a clip (length unverified) | unverified | unverified for Chinese |
| Fish Speech 1.5, OpenAudio S1 mini [25] | CC BY NC SA 4.0 | **no** | 0.5B for S1 mini | both | MLX ports exist | short clip | unverified | strong reputation, unverified here |
| Fish Audio S2 Pro [26] | Fish Audio Research License | **no**, separate license from Fish Audio | large (unverified) | both | MLX in speech-swift (experimental) and mlx-audio-swift | short clip | unverified | unverified |
| XTTS v2 [27] | Coqui Public Model License | **no**. Coqui is reported to have closed in January 2024, so nobody may be left to sell a license (unverified) | about 1.8 GB (unverified) | both, 17 languages | no MLX port known (unverified) | about 6 s | unverified | good, but no longer maintained by Coqui |
| Kokoro 82M [28] | Apache 2.0 | yes | 82M, about 170 MB | English, and a separate v1.1 zh model | Core ML in speech-swift | **no cloning**, fixed voices | about 450 ms after a 20 s first compile, measured by others | 3.90% round trip WER |
| Apple Personal Voice [29][30][31][32] | part of macOS | for the user's own voice, Apple asks for sensitive use | built in | English (US), Mandarin (China mainland) and Spanish (Mexico) on macOS 26 | system | the user reads about 150 phrases, 15 to 20 minutes, then the Mac trains for hours | unverified | good, the user's real voice |

Notes on the table:

- The first audio numbers for Qwen3-TTS are without a cloned voice. The cloned path adds
  a speaker encoder pass that speech-swift caches per sample, so it should cost little
  after the first sentence (unverified, to be measured).
- None of the cloning models was measured on this Mac. A short benchmark on the public
  #40 corpus, with results under bench/, is the first step before any choice.
- Only Qwen3-TTS, CosyVoice 3 and 2, and Chatterbox are open for commercial use and clone
  voices in both languages. Orra is free today, but F5, Fish and XTTS would block any
  later commercial use and are excluded.
- **Personal Voice** has the best consent story, because the user records it in System
  Settings and macOS asks the user before an app may use it.
  `AVSpeechSynthesizer.requestPersonalVoiceAuthorization` is available from macOS 14.0
  [29]. But two reports matter for phase 3. Buffer callbacks
  (`write(_:toBufferCallback:)`) are reported not to work with personal voices, and
  speech then goes to the normal output [31]. That means Orra could not send it to "Orra
  Voice" except by making that device the default output (unverified). And Apple's
  guidance frames Personal Voice for augmentative and alternative communication apps
  [30]. Worth a one day spike. Not a safe base for phase 3 until both are checked.
- Memory: Qwen3-ASR 1.7B (2.47 GB on disk), Qwen3.5 4B (about 4 GB in use) and a voice
  model of 1 to 2 GB together need a 16 GB Mac, more with phase 1's own speech model
  running on the other side's audio. All of them share the GPU, so a translation and a
  caption can wait on each other.

### Latency budget

From the moment the user stops speaking to the first sound the meeting app receives:

| Step | Estimate | Source |
|---|---|---|
| End of speech | 0 ms with the translation key (release), 400 to 700 ms with a voice activity detector | design choice |
| Speech to text, one sentence | 130 to 300 ms on an M5 Pro, more on an M1 | docs/local-asr-models.md |
| Translation, short sentence | about 330 ms on an M5 Pro with the model loaded | README |
| Voice, first chunk | 120 to 225 ms on an M2 Max for Qwen3-TTS, cloned path unmeasured | [8] |
| Core Audio through the loopback device | 10 to 30 ms | unverified, to be measured |
| **Orra's part** | **about 0.6 to 0.9 s with the key, 1.0 to 1.6 s with a detector** | sum |
| The meeting service, network and the other side's buffer | often 150 to 400 ms | unverified, not Orra's |

So the other side hears the translation start about 1 to 2 seconds after the user
finishes a sentence, and hears nothing of it while the user speaks, because translation
waits for the whole sentence. Streaming translation word by word would cut this but changes the
translation step and its checks. Not planned.

Three things can make it worse. A model unloaded after 15 minutes idle needs seconds to
load again, so meeting mode should keep the models loaded. Phase 1 decoding the other
side at the same moment competes for the GPU, so the user's own sentence should go first.
Long sentences take longer in every step, so meeting mode should cut at sentence ends.

### Echo and feedback

- **The other side's voice entering the user's microphone.** Without headphones, the
  speakers play the other side, the microphone hears it, and Orra would translate it and
  speak it into the call in the user's voice. That is the worst failure in this plan.
  Defenses: ask for headphones when meeting mode starts, turn on voice processing for
  the microphone (Apple's echo cancellation), or cancel echo with the phase 1 tap as the
  reference signal, which speech-swift's LocalVQE does with 16 ms of added latency
  [33]. With the translation key, the user decides when Orra listens, which removes most
  of the risk.
- **Orra's own voice in the phase 1 captions.** If Orra plays the translation only into
  "Orra Voice", the speakers never play it, and a tap on the meeting app does not see it.
  If the user wants to hear their own translated voice, the phase 1 tap must exclude
  Orra's process.
- **The user's translated voice coming back** from another participant with poor echo
  cancellation. Phase 1 would caption it as the other side. Orra can drop a caption that
  matches what Orra spoke in the last few seconds.
- **Loops between two Orra users** in one call are possible in theory (each translates
  the other's synthesized voice). Captions are fine, spoken output is not, so meeting
  mode should never speak a translation of system audio.

### Consent, disclosure and misuse

A cloned voice can say things its owner never said. The plan keeps cloning narrow:

- **Only the user's own voice.** The voice is enrolled by reading a sentence shown on
  screen, recorded live in Orra, not imported from a file. That makes it hard to clone
  someone else from a recording. Orra does not offer importing a voice sample.
- **Explicit consent at enrollment,** with text that says what the voice is used for,
  that it stays on the Mac, and how to delete it.
- **What is kept.** Orra's rule today is that no audio is saved. Cloning needs either the
  sample or a speaker vector derived from it. A speaker vector is still biometric data.
  The plan is to keep only the vector, in Application Support, deletable in Settings,
  never in a problem report. Keeping anything at all is a decision for the maintainer.
- **Disclosure to the other side.** The other side should know that the voice they hear
  is synthesized. Options: a short spoken or chat notice when meeting mode starts, a
  label in the user's video (2c), or both. Regulation (EU) 2024/1689, Article 50, asks
  deployers of synthetic audio that resembles a real person to disclose it, and applies
  from 2 August 2026 [34]. China's labeling measures for synthetic content and the
  standard GB 45438-2025 apply from 1 September 2025 and ask for an explicit label on
  synthetic audio, which can be spoken [35]. How these apply to a free local tool used by
  one person in a call is unverified and is not legal advice.
- **Misuse.** The voice speaks only Orra's translation of what the user just said, never
  typed text, so Orra is not a general voice cloning tool. Keeping it that way is part of
  the design, not a limit to remove later.
- Microsoft's Teams interpreter takes a similar line: voice simulation only with the
  speaker's consent, and no stored voice data [18][19].

### Privacy

Everything runs on the Mac: speech, translation and voice. No audio and no text is
written to disk or the log. The only exception would be the speaker vector above, if the
maintainer allows it. The voice model download is a new network step, like the other
models, from the same servers with the same hash checks. The other side receives the
synthesized speech, which carries what the user said, as with any microphone.

### Permissions, keys and entitlements per part

| Part | Needs |
|---|---|
| Phase 1, system audio through a process tap | `NSAudioCaptureUsageDescription` in Info.plist. A developer reported that the `INFOPLIST_KEY_` build setting route drops this key, so it may have to go into Orra/Info.plist directly (unverified) [36]. The user approves System Audio Recording once. |
| 2a, paste into chat | nothing new (Accessibility) |
| 2b, shareable caption window | nothing new for Orra. The meeting app needs Screen Recording. |
| 2c, virtual camera | `com.apple.developer.system-extension.install`, a camera extension target, `NSCameraUsageDescription`, app in /Applications, user approval of the extension |
| Continuous microphone in meeting mode | the existing `NSMicrophoneUsageDescription`, but its text says "while you hold the talk key", so it should be reworded |
| 3a, user installed loopback | nothing new for Orra |
| 3c, Orra Voice driver | admin password at install, a signed and notarized .pkg (Developer ID Installer certificate), a driver bundle signed with Developer ID. No entitlement for Orra. The meeting app uses its existing microphone permission. |
| Voice model | no permission. A download the user agrees to. |
| Personal Voice | the user's authorization through `requestPersonalVoiceAuthorization`, revocable in System Settings. Unverified whether an Info.plist key is needed. |

## Recommended order

1. **2a, send to chat** (1 to 2 days). Uses everything that ships, gives the user a two
   way conversation with phase 1 at once.
2. **2b, shareable caption window** (3 to 5 days). Reuses phase 1's window. Push to talk
   only.
3. **Voice benchmark** (2 to 3 days). Qwen3-TTS 0.6B and 1.7B and CosyVoice 3 through
   speech-swift, cloned from a consenting speaker's sample on the public #40 corpus:
   first audio, real time factor, memory, Chinese and English round trip error, cross
   lingual speaker similarity, on an M5 Pro and if possible an M1 with 16 GB. Results go
   to bench/, never the repo. Plus a one day Personal Voice spike.
4. **3a, speak into a loopback device the user chose** (1 to 2 weeks). Voice enrollment,
   consent, the switch routing, echo guards and disclosure, all testable in real calls
   without shipping a driver.
5. **3c, Orra Voice driver** (2 to 4 weeks), only after the maintainer decides on a
   driver, its license base and the installer.
6. **2c, virtual camera** (4 to 6 weeks), last, if users ask for subtitles on video.

Rough total for phases 2 and 3 with the driver: 10 to 14 weeks of work for one person,
plus manual tests in Zoom, Teams and Meet.

## Decisions for the maintainer

- **Dependencies:** linking `Qwen3TTS` or `CosyVoiceTTS` from speech-swift (no new
  package, but new products and a bump of the pinned commit is likely). Which voice
  model, after the benchmark.
- **A driver:** whether Orra ships an Audio Server plug in at all, with an admin
  install, a .pkg and a coreaudiod restart, or stays with 3a and 3b.
- **Driver license base:** Apple's MIT sample or libASPL (MIT) versus BlackHole (GPL 3,
  or a paid license).
- **Model licenses:** confirm that only commercially usable weights are allowed
  (Apache 2.0 or MIT), which rules out F5-TTS, Fish and XTTS.
- **Info.plist and entitlements:** `NSAudioCaptureUsageDescription` for phase 1,
  rewording `NSMicrophoneUsageDescription`, and for 2c the system extension entitlement
  and `NSCameraUsageDescription`.
- **Saving a speaker vector** for the cloned voice, against the rule that no audio is
  saved.
- **Continuous listening** in meeting mode, or push to talk only.
- **Disclosure:** what Orra tells the other side when it speaks in the user's voice.

## Sources

Read on 2026-10-14 unless a date is given.

1. BlackHole README and license: https://github.com/ExistentialAudio/BlackHole
2. Background Music README and license: https://github.com/kyleneideck/BackgroundMusic
3. libASPL, MIT: https://github.com/gavv/libASPL
4. Apple, Creating an Audio Server Driver Plug-in (sample download with LICENSE.txt): https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
5. speech-swift README, models and products: https://github.com/soniqo/speech-swift
6. speech-swift Package.swift at the pinned commit: https://github.com/soniqo/speech-swift/blob/1f54e56cf137078ed681a03e0955e777f7314610/Package.swift
7. Qwen3-TTS 12Hz 0.6B Base model card: https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base
8. speech-swift TTS benchmarks and Qwen3-TTS first packet latency: https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/tts-roundtrip.md and https://github.com/soniqo/speech-swift/blob/main/docs/inference/qwen3-tts-inference.md
9. Fun-CosyVoice 3 0.5B model card: https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512
10. speech-swift CosyVoice notes and MLX sizes: https://github.com/soniqo/speech-swift/blob/main/docs/models/cosyvoice-tts.md
11. CosyVoice 2 0.5B model card and CosyVoice repository (Apache 2.0): https://huggingface.co/FunAudioLLM/CosyVoice2-0.5B and https://github.com/FunAudioLLM/CosyVoice
12. Apple, Create camera extensions with Core Media IO (WWDC22): https://developer.apple.com/videos/play/wwdc2022/10022/
13. Apple Developer Forums, camera extension not available after activation: https://developer.apple.com/forums/thread/734259 and OBS forum, virtual camera on macOS 14.1: https://obsproject.com/forum/threads/virtual-camera-problems-macos-14-1-obs-29-1-3.170516
14. Apple, Create audio drivers with DriverKit (WWDC21): https://developer.apple.com/videos/play/wwdc2021/10190/
15. Apple Developer Forums, AudioDriverKit for virtual devices: https://developer.apple.com/forums/thread/682035
16. mlx-audio, MIT: https://github.com/Blaizzy/mlx-audio
17. mlx-audio-swift, MIT: https://github.com/Blaizzy/mlx-audio-swift
18. Microsoft Inside Track, Interpreter in Teams meetings: https://www.microsoft.com/insidetrack/blog/deploying-our-new-game-changing-interpreter-agent-in-our-meetings-at-microsoft
19. TechCrunch, 2024-11-19, Teams voice simulation with consent: https://techcrunch.com/2024/11/19/soon-microsoft-will-let-teams-meeting-attendees-clone-their-voices/
20. Zoom community and Berklee guide, sharing computer sound: https://online.berklee.edu/help/en_US/zoom/how-to-share-audio-in-zoom
21. Google Workspace Updates, 2025-12, share device audio when presenting: https://workspaceupdates.googleblog.com/2025/12/share-devices-audio-when-presenting.html
22. F5-TTS model card (CC BY NC 4.0) and code (MIT): https://huggingface.co/SWivid/F5-TTS and https://github.com/SWivid/F5-TTS
23. speech-swift voice cloning benchmark on an M5 Pro: https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/voice-cloning-tts.md
24. Chatterbox model card, MIT: https://huggingface.co/ResembleAI/chatterbox
25. Fish Speech 1.5 model card, CC BY NC SA 4.0: https://huggingface.co/fishaudio/fish-speech-1.5 and Fish Audio, introducing S1: https://fish.audio/blog/introducing-s1/
26. Fish Audio S2 Pro license: https://huggingface.co/fishaudio/s2-pro/blob/main/LICENSE.md
27. XTTS v2 model card, Coqui Public Model License: https://huggingface.co/coqui/XTTS-v2
28. Kokoro 82M and v1.1 zh model cards, Apache 2.0: https://huggingface.co/hexgrad/Kokoro-82M and https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh
29. Apple, requestPersonalVoiceAuthorization(completionHandler:): https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/requestpersonalvoiceauthorization(completionhandler:)
30. WWDC23, Extend Speech Synthesis with personal and custom voices (notes): https://wwdcnotes.com/documentation/wwdc23-10033-extend-speech-synthesis-with-personal-and-custom-voices/
31. Apple Developer Forums, Personal Voice and buffer callbacks: https://developer.apple.com/forums/thread/736148 and TCC access on the Mac: https://developer.apple.com/forums/thread/757828
32. Apple, macOS Tahoe feature availability (Personal Voice languages): https://www.apple.com/macos/feature-availability/ and 9to5Mac, 2026-03-19: https://9to5mac.com/2026/03/19/ios-26-made-one-of-iphones-wildest-most-unique-features-a-lot-better/
33. speech-swift echo cancellation (LocalVQE): https://github.com/soniqo/speech-swift/blob/main/docs/inference/echo-cancellation.md
34. Regulation (EU) 2024/1689, Article 50: https://eur-lex.europa.eu/eli/reg/2024/1689/oj
35. DS Avocats summary of China's labeling measures and GB 45438-2025: https://www.dsavocats.com/mailing/Asia%20News/20250326%20Flash%20Info%20EN.pdf
36. Apple Developer Forums, requesting System Audio Recording, and AudioCap sample (BSD 2): https://developer.apple.com/forums/thread/771864 and https://github.com/insidegui/AudioCap
