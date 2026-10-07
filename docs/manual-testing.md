# Manual testing checklist

State of the repository after the overnight session of 2026-10-02, with manual
results added on 2026-10-03, 2026-10-05 and 2026-10-06, the fn hotkey added on
2026-10-04, local dictation added in the night of 2026-10-04, the choice of talk key and
of microphone added on 2026-10-05, and the model download added on 2026-10-07. Three
sections: what a build or test run verified, what only a person at the Mac can verify, and
what does not exist yet.

Build and test commands, run in the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test

## Automatically verified

- The build command ends in BUILD SUCCEEDED on Xcode 27.0 (27A266a) and macOS 26.6.2,
  with no warnings in Orra's own code. Besides an appintentsmetadataprocessor note about a
  missing AppIntents dependency, which is a tool message, a full build logs four Metal
  compiler warnings from headers inside mlx-swift ("constexpr if is a C++17 extension"),
  which are third party code.
- The test command ends in TEST SUCCEEDED with 304 test cases, including the real model
  tests below. Two heavier real model tests are skipped unless asked for.
  - PushToTalkStateMachineTests covers the full transition table (3 states by 5 events,
    15 rows) and each edge case decision, including cancel.
  - TalkKeyDetectorTests covers, for fn as before, a hold of fn alone, Caps Lock, fn with
    another modifier, modifier rollover, a key or modifier during a hold (Fn+Delete), key
    code 179, arrows carrying the fn flag, release without press, repeated presses, that
    other keys are never swallowed, and reset. For right Control it covers a hold whose
    events pass through, left Control, left Control held before or during a hold, other
    modifiers, right Control+C, a click during a hold, and keyboards without left and
    right bits in both orders of the two Control keys. It also covers right Option and
    right Command, fn passing through when it is not a talk key, two talk keys at once,
    changing the keys during a hold, runs into the state model, and thousands of random
    presses that check that only fn's own events are ever swallowed and that nothing stays
    held once every key is up.
  - HotkeyTapTests feeds the tap's handler without installing a tap: removing the held key
    ends the recording, a click ends a right Control hold, only fn is swallowed, and a tap
    the system switched off, after a timeout or on user input, ends the hold, removes
    itself, tells its owner and does not switch itself back on.
  - TalkKeyTests checks the key codes and left and right bits against the system headers,
    the default of right Control, reading a release on keyboards without those bits, which
    keys change what a click does, the menu hint, and that only fn swallows its events.
    TalkKeyPreferenceTests saves and loads the choice in UserDefaults suites of its own,
    never Orra's. PushToTalkControllerTests checks that changes are saved and that the
    last key stays on.
  - MicrophoneCheckTests covers telling a microphone that delivers zeros from a quiet one,
    that none of the 600 evaluation clips counts as silent, the menu line for a closed
    lid, another input or an unknown one, and reading the default input and the lid state.
    PushToTalkControllerTests checks that such a recording shows that line and the Sound
    settings button, and never reaches the model or the paste.
  - MicrophoneChoiceTests covers the menu labels, the lid warning for the microphone in
    use, refreshing the device list and telling the menu, and saving the choice in
    UserDefaults suites of its own. MicrophoneCheckTests reads this Mac's inputs and finds
    each one again by its UID, and checks the private aggregate rule and the internal
    microphone rule on made up devices. InputUnitTests covers the sample format, the
    capture buffer, that a released device watch removes its listeners, and building and
    initializing an audio unit for each wired input of this Mac without starting it.
    PushToTalkControllerTests checks that the choice is saved and passed to each
    recording, that a silent recording names the microphone that recorded and points to
    Orra's own choice when the chosen microphone recorded, that a missing chosen
    microphone is named on a line of its own, and that one that cannot start is named with
    both steps out.
  - AudioRecorderTests covers taking only the first input channel of plain and
    interleaved buffers, resampling a whole recording from 48, 44.1 and 24 kHz to 16 kHz
    without losing the end, the sample store limit, and the length rules. They use
    synthetic buffers, not the microphone.
  - TextInserterTests covers pasting with Command V, restoring the old pasteboard, keeping
    what the user copied afterwards, pasting while another process holds secure input,
    leaving a password field and the pasteboard alone, leaving a field that cannot be
    described alone when the app in front holds secure input, pasting into plain text
    there, asking about the field only under secure input and only right before the paste,
    telling fields apart by role and subrole, a concealed Copy Last Dictation, empty text,
    two dictations in a row, restoring several items and types, reading the pasteboard off
    the main actor, and finding the key for v in the current layout with and without
    Command held. They use private named pasteboards and a fake key poster, so no real
    event is posted.
  - PushToTalkControllerTests runs the whole flow with a fake microphone, a fake speech
    model, a fake inserter and a fake frontmost app: model loading, trying a failed load again, and the ready gate,
    record, resample, transcribe and paste, a release or cancel that arrives before the
    microphone has started, a new hold that begins while a cancelled one is still
    stopping the microphone, the minimum hold, a recording cut by a device change, a
    recording without samples, empty text, loops, traditional characters, an app switch
    before the paste, failures including a failed start, a password field, presses during
    processing, cancel, microphone permission states including a build without a usage
    description, the 60 second limit, and that start leaves loading the model to the model
    installer. With a fake in place of the keyboard tap and the access check, it checks
    that the menu shows the talk key as off as soon as the system switches the tap off,
    that a new tap is installed after the pause while access is there, and that no tap
    comes back when the access check says no, or still says yes while the system refuses
    the tap. It also checks that the environment variable the launch guard relies on is
    set while tests run, the cues for the recording indicator and the sounds in order
    for a dictation, a short hold, a cancel, a failed start, a password field and empty
    text, the reasons a hold cannot record, and reading microphone permission again.
  - RecordingFeedbackTests checks what the indicator shows and which sound plays for each
    cue, a message that goes after a while without hiding the next hold, the indicator
    and the sounds turned off, saving both choices, the level meter's scale and how it
    rises and falls, and that the indicator's panel can never become key or main. It
    uses fakes, so no window opens and no sound plays. LevelMeterTests checks the peak
    the audio thread stores.
  - TranscriptGuardTests and ChineseTextTests cover loop cutting that leaves phone numbers
    and codes intact, the length cap, and the conversion of traditional characters that
    leaves valid simplified text such as 乾隆, 著书 and 俱乐部 alone, converts 後 and 於,
    keeps 噁, and leaves Japanese alone.
  - SupportTests covers the test scoring helper, the memory footprint helper, that the
    model loads only from a complete installed folder, tokenizer files included, and that
    the engine reports a missing model without loading anything.
  - ModelFilesTests covers the pinned files, their sizes and hashes, the three server
    addresses and their order, the Debug launch argument that forces one server, the
    app's folder paths, the size and SHA-256 checks, and what launch does with local files
    only: finding the installed model, finishing an install a quit interrupted, cloning
    the old cache copy in either layout without changing it and with no free space, so
    only a clone can do it, keeping a partial download over an old copy, dropping a
    damaged old file,
    moving an incomplete or damaged install back to the staging folder, the backup flag,
    and removing other revisions. It works in temporary folders.
  - ModelDownloadTests runs the real URLSession code against stand in servers behind a
    URLProtocol in the session configuration, so no request leaves the test process: a
    plain download, moving on at once from a server that cannot be reached or answers 404
    or 403, no network at all, resuming the weights with a Range request, small files
    always fetched whole, the cut 200 body and the 502 on a ranged request that
    modelscope.cn sends, a server that ignores ranges, a 200 that names a range, a
    dropped connection resumed from the bytes on disk after a pause, a request that ends
    before the fetch waits for it, as a cancel just before a request does, wrong bytes fetched
    again from the next server, every server failing and Try Again, too little space
    without a request, cancel keeping the partial file, too many bytes, a wrong
    Content-Range, files that cannot be written, the idle timeout each request is given
    (8 s for the first request to a server, 30 s after that, not a stalled server), and at
    most one progress report per 0.25 s.
  - ModelInstallerTests checks that launch and Try Again after a failed load never fetch,
    the order of states from checking to installed, that each install calls onInstalled
    once, that Download does nothing while a download runs or before the check, cancel
    and resume, that Orra holds a process activity only during a download, Try Again
    after a failure, the space check, hashing the installed files after a failed load,
    and the installer's menu text and icon symbol for every state. The wiring that loads
    the model after an install, the activity's effect on sleep and the menu bar icon
    itself are manual checks below.
  - OpenAtLoginTests covers reading the login item status again, telling the menu about
    every change, turning it on and off, a failed change and when its message clears, and
    an item waiting for approval, with a fake in place of the system's login items.
  - Qwen3EngineTests loads the real Qwen3-ASR 1.7B model and transcribes 10 public clips,
    5 from fleurs_zh and 5 from ascend_mixed. It may make at most 18
    errors in their 214 tokens, against 14 measured on 2026-10-05 in every run. It checks
    that the warm up read the weights, then transcribes 10 more clips and compares the
    median memory of the same five clips early and late, and against the reading after
    loading. docs/asr-baseline.md has the numbers.
  - DictationQualityTests runs the real model the way dictation uses it: holds with only
    silence, noise or hum give no text, pauses before or after speech change at most one
    token, 48 kHz audio through the whole controller matches the direct result, and about
    60 s of speech in one dictation stays as accurate as the clips one by one. With
    TEST_RUNNER_ORRA_FULL_EVAL=1 it also runs all 600 evaluation clips, and with
    TEST_RUNNER_ORRA_SOAK=1 it runs 200 dictations in a row to watch memory. Both real
    model suites sit under RealModelTests, which runs them one at a time. They load the
    model from Orra's installed folder, or, before a build with the model download has
    run once, from the copy in ~/Library/Caches/qwen3-speech, which they only read.
- The secure input check reads kCGSSessionSecureInputPID. A throwaway program turned secure
  input on and off on 2026-10-04 and saw the key appear and disappear.
- The built app launches from the terminal, finishes launching, and reports the
  accessory activation policy through NSRunningApplication. LaunchServices lists it as
  type UIElement. It exits cleanly on SIGTERM. This was a one off smoke run from the
  terminal, not part of the test suite.
- Orra/ and OrraTests/ are synchronized folder groups, so the new Swift files were
  picked up with no project file edits.

## Needs manual verification

Checked items were verified by the maintainer on 2026-10-03 unless the item gives another
date, running the app from
Xcode 27.0 on macOS 26.6.2 on a MacBook with a notch. Unchecked items are still open.

- [x] No Dock icon at launch, and no flash was noticed. The policy is set in
  applicationWillFinishLaunching rather than through LSUIElement.
- [x] No window opens at launch. Only the mic icon appears in the menu bar.
- [x] The menu shows "Settings…" and "Quit Orra". Since 2026-10-04 a hotkey status line
  sits above them, see the fn hotkey list below.
- [x] "Settings…" opens the placeholder window and brings it to the front while another
  app is active. Tried with Safari frontmost. Since 2026-10-05 the window holds the talk
  key switches and the microphone choice instead of the placeholder.
- [x] Choosing "Settings…" again while the window is behind another app brings the same
  window forward and does not open a second one.
- [x] Command W closes the settings window, and "Settings…" reopens it.
- [ ] The close button closes the settings window, and "Settings…" reopens it.
- [x] "Quit Orra" quits.
- [x] Command Q while the settings window is focused quits.
- [x] Xcode opens the project and shows the new files in the Orra folder and the Orra
  scheme.
- [x] Xcode runs the tests from Product > Test, and they pass.
- [ ] The SettingsView preview renders in Xcode.
- [ ] The project settings the maintainer changed before the session (macOS 15.6, Swift 6,
  App Sandbox off, Bundle ID, Development Team) are what they expect. They were
  committed unchanged in the baseline commit.

Fn hotkey, added on 2026-10-04, not verified yet. Since 2026-10-05 fn is no longer the
default talk key. Turn it on under Talk Key in the menu for the fn checks:

- [ ] At launch without Accessibility access, the system prompt appears, the menu bar
  icon is a crossed out mic, and the menu shows "The talk key needs Accessibility access"
  and "Grant Accessibility Access…".
- [ ] After turning Orra on under System Settings > Privacy & Security > Accessibility,
  within a few seconds the icon becomes a plain mic and the menu shows "Hold right
  Control to talk", or the keys that are on, without relaunching.
- [ ] Holding fn alone fills the mic icon, and releasing it brings back the plain mic.
- [ ] Holding or tapping fn no longer triggers the "Press fn key to" action set under
  System Settings > Keyboard, such as switching the input source.
- [ ] Fn+Delete still deletes forward and Fn+arrows still jump, and the icon returns to
  the plain mic.
- [ ] Fn pressed while Command or Shift is already held does not fill the icon.
- [ ] Typing in other apps feels the same while Orra runs.
- [ ] After quitting Orra, the fn key behaves as before.
- [ ] Running the tests shows no Accessibility prompt.
- [ ] Opening the SettingsView preview shows no Accessibility prompt, and Orra run from
  Xcode still reacts to fn while the preview is open.
- [ ] Known blind spot, check how it behaves: with Terminal > Secure Keyboard Entry on,
  holding fn still fills the icon, and Fn+arrows fill it too instead of being ignored.
- [ ] Known blind spot, check how it behaves: with "Use F1, F2, etc. keys as standard
  function keys" on, Fn+F12 still changes the volume, and the icon fills while fn is
  held.

Talk key choice, added on 2026-10-05, not verified yet:

- [ ] With the default, holding right Control on an external keyboard such as a Logitech
  MX Keys fills the mic icon, and a dictation works.
- [ ] Talk Key in the menu and the Settings window show the same switches. Turning on fn
  changes the menu to "Hold right Control or fn to talk", and fn on the Mac keyboard then
  works too. The last key that is on cannot be turned off.
- [ ] While fn is not a talk key, it keeps its "Press fn key to" action and is never
  swallowed.
- [ ] Left Control does not start a dictation, and right Control+A still moves the cursor
  to the start of the line in a text field.
- [ ] A right Control click in Notes or Finder opens the context menu and starts no
  dictation, even while someone nearby is talking.
- [ ] With Keyboard > Dictation > Shortcut set to "Press Control Key Twice", tap right
  Control and then hold it. Note whether macOS Dictation starts as well. Do the same with
  right Command turned on and Siri set to a double press of Command.
- [ ] Holding right Control alone does not disturb the frontmost app, and the Chinese
  Pinyin input method keeps its Chinese or English mode.
- [ ] The choice of keys is still there after quitting and reopening Orra.
- [ ] Right Option and right Command work the same way when turned on.

Tap switched off by the system, changed on 2026-10-06, not verified yet. The log lines
below show with the log stream command under Testing notes:

- [ ] Run Orra from Xcode and dictate once. Pause Orra with Debug > Pause, then press one
  key in another app. Orra's tap cannot answer, so the key waits until macOS switches
  the tap off. Click Continue in Xcode. The icon shows the crossed out mic for about two
  seconds, then the plain mic, and the talk key dictates again. The log shows "The
  system switched the keyboard tap off after a timeout, tap removed", then "Hotkey
  active".
- [ ] Only with a way into the Mac from another computer, such as SSH, because input can
  freeze: while Orra runs, turn it off under Privacy & Security > Accessibility. Another
  time, remove it from the list instead. Each time, note whether keyboard and mouse
  input freeze, whether the icon becomes the crossed out mic, and which of these log
  lines appear: "The system switched the keyboard tap off", "The system refused the
  keyboard tap", "Accessibility access is gone, keyboard tap removed". If input
  freezes, take a sysdiagnose over SSH before restarting.

Microphone choice, added on 2026-10-05, partly verified. docs/microphone-choice.md
explains how it works. A chosen microphone records through its own audio unit, which no
test starts, so these checks are the first real recordings through it:

- [ ] Microphone in the menu lists the inputs of System Settings > Sound > Input, with
  "System Default" first and without Microsoft Teams Audio. With the lid closed, the
  built in microphone reads "MacBook Pro Microphone (lid closed)", and the menu shows
  "The lid is closed, so the built in microphone is off" while that microphone is the
  one Orra would record from.
- [x] With the lid closed and the MacBook microphone as the system default, choose the
  Brio 500 and dictate without relaunching Orra: the text arrives. The maintainer
  reported no problems on 2026-10-05.
- [ ] In the same setup, the system default input in System Settings is unchanged, and
  the microphone indicator goes off after the release. If the menu says "Brio 500 could not start", or "No sound came from Brio
  500" while you spoke, the audio unit does not work on this Mac. Choose System Default
  and set the Brio in System Settings instead, and keep the log lines below. The menu
  names these steps in both cases.
- [ ] Choose the iPhone microphone and dictate.
- [ ] The choice is still there after quitting and reopening Orra, and the Settings
  window shows the same choice and changes it too.
- [ ] Unplug the chosen microphone between two dictations: the menu lists it as "(not
  connected)", the next dictation records from the system default, and the menu names
  the microphone that recorded. Plug it back in: the next dictation uses it again.
- [ ] Unplug the chosen microphone during a hold: the menu says "The microphone changed
  during the recording. Try again." and nothing is pasted.
- [ ] If AirPods are around: choose them while the default input stays on the Brio, and
  dictate. Then choose the Brio while AirPods are the default input, play music, and
  dictate: the music should keep its quality, because only the Brio is opened.
- [ ] The log names the path of each hold, without device names:
  `log show --last 10m --predicate 'subsystem == "io.github.db-ol.Orra" AND category == "audio"'`
  shows "Recording from the chosen microphone over usb  at 48000 Hz, started in ...
  seconds" or "Recording from the system default input".

Local dictation, added on 2026-10-04, partly verified by hand.
The package, the microphone usage description, the Metal Toolchain and the plugin trust
are in place since 2026-10-05:

- [ ] At launch the icon shows an hourglass and the menu says "Loading the speech model…",
  then the plain mic appears within a few seconds.
- [ ] The first hold of the talk key shows the macOS microphone prompt and records
  nothing. After allowing access, the next hold records.
- [ ] The orange microphone indicator shows only while the talk key is held.
- [ ] With the lid closed and the MacBook microphone as the default input, a hold shows
  "The lid is closed, so the built in microphone is off" and "Open Sound Settings…",
  which opens System Settings at Sound. After choosing another input there, such as a
  webcam, the next hold records from it without relaunching Orra.
- [ ] First real dictation into Notes: Chinese, English, and both mixed. The text appears
  within about a second of releasing the talk key.
- [ ] Neither the first syllable after pressing the talk key nor the last word before
  releasing it is cut off. Orra keeps recording for 150 ms after the release.
- [ ] Install a Release build as README.md describes, turn on Open at Login, then log out
  and back in: Orra starts by itself. If the menu shows "Allow Orra in Login Items…", it
  opens System Settings at Login Items & Extensions.
- [ ] Open the menu twice after turning Open at Login on: the check mark shows both times.
- [ ] Turn Open at Login off: Orra disappears from System Settings > General > Login Items
  & Extensions, under Open at Login.
- [ ] After a few days of use, check how long dictations took:
  `log show --last 3d --predicate 'subsystem == "io.github.db-ol.Orra"' | grep "Release to paste"`.
  Most should be well under a second. Note any that took longer, see Stalls under Inside
  Orra in docs/asr-baseline.md.
- [ ] A dictation longer than 15 seconds that repeats a number or a phrase, for example
  "16th in 2025 and 16th in 2026", keeps every repetition.
- [ ] Copy something first, then dictate. Afterwards the clipboard holds the old content
  again, and a clipboard manager does not record the dictated text.
- [ ] Copy a large range in Excel or Numbers, or copy something on an iPhone, then
  dictate. Typing on the Mac does not stall while Orra saves the old clipboard.
- [ ] Release the talk key and switch to another app at once. The text is not pasted
  there, the menu says so, and "Copy Last Dictation" copies it.
- [ ] Pasting works in Notes, a browser text field, VS Code and Terminal.
- [x] In the password field of a login form in Safari and in Chrome, nothing is pasted,
  the clipboard keeps what it had, the menu says "Orra does not paste into password
  fields. Use Copy Last Dictation.", and Copy Last Dictation gives the text. Verified by
  the maintainer on 2026-10-06. Dictating into Notes without secure input still pastes
  and puts the old clipboard back.
- [ ] The same in the password field of a System Settings sheet, in Chrome while
  chrome://accessibility shows native accessibility off, and on the unlock screen of a
  password manager built on Electron. After Copy Last Dictation, a clipboard history app
  does not record the text.
- [x] With Terminal's Secure Keyboard Entry on (Terminal menu) and ioreg showing
  kCGSSessionSecureInputPID, dictating into Terminal itself pastes the text, and the old
  clipboard comes back. Verified by the maintainer on 2026-10-06.
- [ ] With Secure Keyboard Entry still on, bring Notes to the front and run
  `ioreg -l -w 0 | grep SecureInput` in another window. Terminal is expected to give
  secure input up when its window is not in front, so dictating into Notes tests the new
  path only when kCGSSessionSecureInputPID still shows there. Write down which it was.
- [ ] Known blind spot, check how it behaves: in Terminal with Secure Keyboard Entry on,
  hold right Control for a series of Control shortcuts for more than a second while
  someone talks. Secure input hides the other keys from Orra, so this can be taken as a
  dictation, and its text is then pasted at the prompt.
- [ ] A quick tap of the talk key does nothing. Holding it for more than 60 seconds stops
  the recording and pastes.
- [ ] Pressing the talk key while the previous dictation is still being processed does
  nothing.
- [ ] Command V still pastes with the Pinyin, ABC, Dvorak and Dvorak QWERTY Command
  layouts.
- [ ] A Bluetooth headset such as AirPods works as the microphone. Connect or remove them
  between two holds: the next hold still records. Connect them during a hold: the menu
  says the microphone changed, and the next hold works. With AirPods as the microphone,
  press the talk key with another key, such as right Control+C, then hold the talk key
  again at once and dictate: the text arrives.
- [ ] With a multichannel audio interface, the voice on input 1 is recognized at its
  normal level, and what the Mac plays is not transcribed.
- [ ] Known risk, check how it behaves: pasting into Screen Sharing, Microsoft Remote
  Desktop or a virtual machine. The old clipboard comes back after 0.5 seconds, which
  may be too early for a remote side that syncs the clipboard late.
- [ ] Activity Monitor shows how much memory Orra holds while idle with the model loaded,
  and after many dictations in a row. Also compare Wired Memory in its Memory tab before
  launching Orra and after the model has loaded, because loading wires the model's
  buffers (see Limits in docs/asr-baseline.md).

Model download, added on 2026-10-07, not verified yet. docs/model-download.md explains
how it works. Watch the download with
`/usr/bin/log stream --predicate 'subsystem == "io.github.db-ol.Orra" AND category == "model-download"'`,
and check connections with `lsof -nP -i -a -c Orra`:

- [ ] Launch makes no connection. With the model installed, and again with it missing,
  `lsof` shows no internet socket for Orra, before and after opening the menu.
- [ ] First launch of this build on the maintainer's Mac, where ~/Library/Caches/qwen3-speech
  holds the model. The menu shows "Preparing the speech model…" briefly, then dictation
  works without a download. ~/Library/Application Support/io.github.db-ol.Orra/Models
  holds Qwen3-ASR-1.7B-MLX-8bit-e5450a26 with six files, and `tmutil isexcluded` on it
  says Excluded. `df -k /` drops by far less than 2.4 GB, the old folder is unchanged,
  and there is still no connection.
- [ ] Fresh state: quit Orra and rename
  ~/Library/Application Support/io.github.db-ol.Orra/Models and
  ~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit. At launch the
  icon is a down arrow in a circle, and the menu shows "Orra needs its speech
  model to transcribe.", "The model comes from Hugging Face or a mirror. Your speech stays
  on this Mac." and "Download Speech Model (2.47 GB)", above the Accessibility line when
  Accessibility is off. There is no connection until Download is chosen.
- [ ] Outside mainland China, or with a VPN, the menu says "From huggingface.co" and the
  download finishes. Note the time it took.
- [ ] In mainland China without a VPN, "From modelscope.cn" appears within about 8 s and
  the download finishes. Note the time it took and the average speed.
- [ ] With a Debug build launched with `-ModelServer hf-mirror.com`, and again with
  `-ModelServer modelscope.cn`, the menu names that server and the model installs.
  Outside mainland China, hf-mirror.com sends every request on to huggingface.co.
- [ ] The percentage changes while the menu stays open. If it only changes when the menu
  is opened again, note it.
- [ ] Cancel at about 30%. The menu offers "Resume Download (… left)", and Resume goes on
  from the same percentage. The log shows a request at the byte reached.
- [ ] When a download finishes, the menu bar icon turns into the plain microphone within a
  few seconds, and a dictation works, without relaunching Orra.
- [ ] Quit during the download, then relaunch: no connection at launch, and Resume goes on.
- [ ] During a download, `tmutil isexcluded` on the .download folder in Models says
  Excluded, and `pmset -g assertions` lists Orra's activity, which keeps the Mac from
  sleeping while idle.
- [ ] Turn Wi-Fi off and choose Download: within seconds the menu says "This Mac is
  offline. Connect to the internet, then try again." Try Again works once Wi-Fi is back.
- [ ] Sleep and wake the Mac during the download. It goes on, or offers Try Again, which
  goes on from the bytes on disk.
- [ ] Cancel after merges.txt has arrived, change one byte in
  `.download-Qwen3-ASR-1.7B-MLX-8bit-e5450a26/merges.txt`, then Resume. merges.txt is
  fetched again, and the model installs.
- [ ] Quit Orra, delete vocab.json from the installed folder, and launch. The menu offers
  Resume Download with 2.8 MB left, and Resume fetches only vocab.json.
- [ ] Quit Orra, change the first byte of model.safetensors in the installed folder, and
  launch. The menu says "The speech model could not be loaded" with Try Again. Try Again
  checks the hashes: with the old cache copy still there, the model is installed again
  from it without a download, otherwise the menu offers Resume Download for the weights.
- [ ] Typing in other apps and opening the menu stay instant during the download and
  during "Checking the downloaded files…".
- [ ] On a Mac with macOS 15.6, if one is at hand, repeat the first four checks.

Recording indicator and sounds, added on 2026-10-07, not verified yet:

- [ ] Hold the talk key in Notes: a short sound plays and a dark indicator appears at the
  bottom of the screen with the pointer, with bars that move with your voice. Notes keeps
  the focus: its text cursor still blinks, and the menu bar still shows Notes.
- [ ] Release: the indicator shows "Transcribing…", a second sound plays, and the
  indicator goes once the text is in Notes. The start sound does not show up as a word
  at the start of the text.
- [ ] Over a full screen app, on another Space, and on a second display with the pointer
  there, the indicator shows the same way.
- [ ] Clicks at the bottom of the screen pass through the indicator.
- [ ] Before the model is ready, and with microphone access off, a hold shows the reason
  in the indicator for a few seconds. Dictating into a password field shows "Orra does
  not paste into password fields. Use Copy Last Dictation." Holding the key without
  speaking shows "No speech was recognized".
- [ ] In Settings, turning off "Show the recording indicator" and "Play sounds when
  recording starts and stops" takes effect at the next hold, and both stay off after
  quitting and reopening Orra.

Testing notes:

- Quit Orra before turning off or removing its Accessibility access. Revoking access
  while its keyboard tap is installed can freeze keyboard and mouse input on current
  macOS versions. See the Decision section of docs/hotkey-options.md.
- Orra logs hotkey events, without key codes, under the subsystem io.github.db-ol.Orra.
  They show in Xcode's console, or in Terminal with
  `log stream --level debug --predicate 'subsystem == "io.github.db-ol.Orra"'`.
- The project must keep its microphone usage description. Without it the menu says "This
  build has no microphone usage description" and holds do not record, because macOS would
  end Orra if it asked for the microphone without one.
- Orra never logs transcript text or audio, only states and timings.
- Run one instance at a time. Starting the app with open and again from Xcode puts two
  identical icons in the menu bar, and quitting one leaves the other running.
- On macOS 26 the menu bar item windows belong to the Control Center process, so window
  listings do not show them under Orra.

## Not implemented

- A longer clipboard restore for remote desktop and virtual machine apps. The delay is
  0.5 seconds everywhere and needs a decision before it changes.
- A choice of model, a personal dictionary, and the onboarding that adapts to the user.
- Key combinations and mouse buttons as talk keys, and hands free mode.
- Rewriting, and settings other than the talk keys, the microphone, the recording
  indicator and the sounds.
