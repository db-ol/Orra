# Manual testing checklist

State of the repository after the overnight session of 2026-10-02, with manual
results added on 2026-10-03, 2026-10-05 and 2026-10-06, the fn hotkey added on
2026-10-04, local dictation added in the night of 2026-10-04, the choice of talk key and
of microphone added on 2026-10-05, and on 2026-10-07 the model download, the recording
indicator and sounds, the welcome window, the Chinese interface and the app icon. Three
sections: what a build or test run verified, what only a person at the Mac can verify, and
what does not exist yet.

Build and test commands, run in the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -testLanguage en -testRegion US test

## Automatically verified

- The build command ends in BUILD SUCCEEDED on Xcode 27.0 (27A266a) and macOS 26.6.2,
  with no warnings in Orra's own code. Besides an appintentsmetadataprocessor note about a
  missing AppIntents dependency, which is a tool message, a full build logs four Metal
  compiler warnings from headers inside mlx-swift ("constexpr if is a C++17 extension"),
  which are third party code.
- The test command ends in TEST SUCCEEDED with 2080 test cases passed, 162 of them filler
  rule cases and 1394 number rule cases, including the real model tests below. Three heavier real model tests are
  skipped unless asked for.
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
    set while tests run, and reading microphone permission again. For the recording
    indicator and the sounds it checks the whole list of cues for a dictation, a short
    hold, a cancel, a failed start, a password field and empty text, that no cue comes
    before the hold has lasted a moment, so a shortcut with the talk key sends none, and
    the message for each reason a hold cannot record: a model that is missing, loading or
    failed to load, and microphone access that is off or impossible in the build.
  - RecordingFeedbackTests checks what the indicator shows and which sound plays for each
    cue, a message that goes after a while without hiding the next hold, the indicator
    and the sounds turned off, the idle bar between dictations, only while Orra can
    dictate, and turned off, that the view draws it, the area where the pointer counts
    as over the bar, saving the choices, the level meter's scale, how it rises
    and falls, and that it reads the microphone only while it is on screen. It makes the
    app's own indicator panel without showing it and checks that the panel can never
    become key or main, lets clicks through, and shows on every Space and over full
    screen apps. It uses fakes for the panel and the sounds otherwise, so no window opens
    and no sound plays. LevelMeterTests checks the peak the audio thread stores.
  - SetupChecklistTests covers the welcome window's three steps: the model step for every
    installer state and for an installed model that is loading or failed to load, the
    microphone step for every permission state, and the Accessibility step. It checks that
    setup counts as complete only once the model has loaded, and that a model that is
    still loading needs nothing from the user, which decides whether launch opens the
    window and the menu shows Setup Guide….
  - VocabularyTests checks how the vocabulary text becomes terms (trimmed, once each
    ignoring case, cut at 40 characters, at most 100), the context string the model gets,
    and saving the list. PushToTalkControllerTests checks that every dictation passes the
    current vocabulary to the model, nil when it is empty, and that a change is saved.
  - CorrectionFinderTests, SoundAlikeTests and CorrectionStoreTests cover finding a fixed
    word in the pasted text (Chinese, a name across scripts, a whole Latin word), leaving
    out changes of meaning, deletions, additions, rewrites and edits outside the paste,
    the pinyin comparison, accepting only pairs that were not undone, and the stored file.
    They also cover separate fixes in one sentence judged one by one, a Chinese name
    widened to its unchanged characters, and the cap of 8 Chinese characters.
    CorrectionWatcherTests drives the watcher with a scripted field, so no app is read: a
    reported fix, and no reading after leaving the app, under secure input, or in a field
    without the pasted text. CorrectionLearningTests checks that nothing is read while
    learning is off, that the first fix adds the word and tells the user, a quiet new
    mishearing, Undo, and that a learned word removed from the vocabulary is learned
    again. LearnedNoticeTests checks the notice and its panel.
    OneCharacterFixTests and WordSuggestionLearningTests cover a fix of one Chinese
    character: grammar pairs never offered, the guessed word from the system tokenizer,
    and adding, editing and declining the offered word.
  - LocalizationTests checks that every string in both catalogs has a Simplified Chinese
    translation marked translated, that each translation keeps the arguments of the
    English string, that the Chinese uses full width punctuation and a space next to a
    Latin word or a number, that the built app carries the Chinese strings, that Chinese
    is chosen only when it comes before English in the preferred languages and never for
    Traditional Chinese alone, and the Chinese talk key hint for one to four keys.
  - TranscriptGuardTests and ChineseTextTests cover loop cutting that leaves phone numbers
    and codes intact, the length cap, and the conversion of traditional characters that
    leaves valid simplified text such as 乾隆, 著书 and 俱乐部 alone, converts 後 and 於,
    keeps 噁, and leaves Japanese alone.
  - FillerRulesTests runs the filler rules on every case of Tools/rewrite-eval/cases.jsonl
    that rules alone should get right (fillers, particles that must stay, and controls),
    checks that the cases that need a model lose only fillers, never a word or a number,
    and covers spacing between Chinese and English, punctuation left behind, capitals at a
    sentence start, replies such as 嗯，好的 and uh-huh, acronyms such as UM, and words
    such as 金额 and 呃逆. PushToTalkControllerTests checks that the paste has the fillers
    removed while the setting is on and not while it is off, and that a change is saved.
  - NumberRulesTests runs the number rules on every case of
    Tools/rewrite-eval/numbers.jsonl and checks that applying them twice changes nothing
    more. It checks that every cleanup in cases.jsonl without a number stays as it is,
    that English is untouched, ranges of times, versions after a Latin name, and a long
    dictation. PushToTalkControllerTests checks that the paste has digits after the fillers
    are gone while the setting is on, not while it is off, and that a change is saved.
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
- ProblemReportTests covers the diagnostic report of Report a Problem…: the home folder,
  account name, full name and computer name are taken out, names under three characters
  and other users' folders stay, the report lists the facts and only counts of the
  vocabulary and the learned pairs, keeps the newest 2000 log lines, picks at most three
  Orra crash reports from the last 7 days, and the issue link fills the form fields the
  bug report form defines, with what happened among them. The link stays under 6,000
  characters, and the sign in link GitHub makes from it under 7,000: a long text is cut
  between whole characters with a marker in English and Chinese, which the tests check
  for English, Chinese and emoji, since percent encoding makes a Chinese character 9
  characters long and an emoji up to several dozen, and the sign in link adds 2 for
  every %. Without a title, the first line of the text is the title, at most 120
  characters and 1,000 encoded, also after a Windows line break.
- On 2026-10-10, curl without a GitHub session asked for
  https://github.com/db-ol/Orra/issues/new with template, title, what-happened, version,
  macos and mac filled in, with Chinese text, a newline, a plus and an ampersand. GitHub
  answered 302 to https://github.com/login?return_to= followed by the whole new issue
  link, encoded once more, with every parameter in it. The sign in page put the same
  link in its return_to field, and its Create an account link went to /signup with the
  same return_to. The sign up page itself answered curl with a bot check, so whether
  GitHub returns to the form after creating an account was not verified. With English
  text, links up to 6,979 characters got the 302, and links of 7,079 characters and
  more got a 500. With Chinese text or emoji the sign in link is the limit, since every
  % in the issue link becomes %25 there, about 1.67 times as long. A 4,620 character
  link with Chinese text got a sign in link of 7,693 characters with the issue link
  intact. From a 4,680 character link with emoji and a 4,800 character link with
  Chinese text, GitHub sent a 302 to plain https://github.com/login with no return_to,
  so the form would come back empty after signing in. The sign in link was always
  https://github.com/login?return_to= followed by the issue link encoded the way Orra
  encodes. So Orra keeps its links under 6,000 characters and the sign in link under
  7,000. A one off run on 2026-10-10 wrote a report on this Mac from
  the local log store, with a crash report, and without the home folder or the account
  name in it.
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
- [x] Once the model and both permissions are in place, no window opens at launch. Only the
  mic icon appears in the menu bar. Since 2026-10-07 the welcome window opens until then.
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
default talk key. Turn it on under Talk Key in the menu for the fn checks, and keep "Show
the recording indicator" on in Settings. The indicator shows only once the microphone
records, so for the checks that expect no indicator, also listen for no start sound and
look for no orange microphone indicator in the menu bar:

- [ ] At launch without Accessibility access, the welcome window appears instead of the
  system prompt, the menu bar icon is a crossed out mic, and the menu shows "The talk
  key needs Accessibility access" and "Grant Accessibility Access…".
- [ ] After turning Orra on under System Settings > Privacy & Security > Accessibility,
  within a few seconds the icon becomes a plain mic and the menu shows "Hold right
  Control to talk", or the keys that are on, without relaunching.
- [ ] Holding fn alone shows the recording indicator, and releasing it ends the dictation.
- [ ] Holding or tapping fn no longer triggers the "Press fn key to" action set under
  System Settings > Keyboard, such as switching the input source.
- [ ] Fn+Delete still deletes forward and Fn+arrows still jump, and no recording
  indicator stays on screen.
- [ ] Fn pressed while Command or Shift is already held shows no recording indicator,
  plays no start sound, and turns on no orange microphone indicator.
- [ ] Typing in other apps feels the same while Orra runs.
- [ ] After quitting Orra, the fn key behaves as before.
- [ ] Running the tests shows no Accessibility prompt.
- [ ] Opening the SettingsView preview shows no Accessibility prompt, and Orra run from
  Xcode still reacts to fn while the preview is open.
- [ ] Known blind spot, check how it behaves: with Terminal > Secure Keyboard Entry on,
  holding fn still shows the indicator, and Fn+arrows show it too instead of being ignored.
- [ ] Known blind spot, check how it behaves: with "Use F1, F2, etc. keys as standard
  function keys" on, Fn+F12 still changes the volume, and the indicator shows while
  fn is held.

Talk key choice, added on 2026-10-05, not verified yet:

- [ ] With the default, holding right Control on an external keyboard such as a Logitech
  MX Keys shows the recording indicator, and a dictation works.
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

Welcome window, added on 2026-10-07, not verified yet. For a clean first launch, quit Orra
first. With Orra quit, move ~/Library/Application Support/io.github.db-ol.Orra/Models and
the two old cache folders named in README.md out of the way (do not delete them), run
`tccutil reset Microphone io.github.db-ol.Orra` (Microphone only, never All), and turn
Orra off under System Settings > Privacy & Security > Accessibility. Never turn off or
remove Orra's Accessibility access while it runs. Undo all of it afterwards:

- [ ] At launch the welcome window opens in front of other apps, with three steps:
  Download the speech model, Allow the microphone, Allow Accessibility. No system prompt
  appears on its own.
- [ ] Before doing any step, click Not Now: the menu shows Setup Guide…, which opens the
  window again. Quit Orra and launch it: the window opens again.
- [ ] Download Speech Model starts the download, shows a progress bar, the percentage and
  the server, and Cancel Download stops it. The menu shows the same progress.
- [ ] While the model downloads, Allow Microphone Access… shows the macOS prompt, and the
  step gets its check mark after Allow.
- [ ] Grant Accessibility Access… shows the macOS prompt. After turning Orra on in the
  list, the step shows "Hold right Control to talk", or the keys that are on, within a
  few seconds.
- [ ] After the download, the model step shows a spinner and "Loading the speech model…",
  then its check mark. Only then does the window say "Orra is ready", and Done closes it.
  The menu has no Setup Guide…, and the next launch shows no window.
- [ ] Later, quit Orra, turn it off under Microphone in System Settings > Privacy &
  Security, and launch it: the microphone step offers Open Microphone Settings…, and
  turning Orra on there gives the step its check mark within a second, without a
  relaunch.
- [ ] Launched as a login item with steps left, the welcome window still comes to the
  front.

Chinese interface, added on 2026-10-07, not verified yet. Give Orra its own language under
System Settings > General > Language & Region > Applications: add Orra with Chinese,
Simplified, then quit and reopen it. Afterwards set it back:

- [ ] The menu, its submenus, Settings, the welcome window and the recording indicator are
  in Chinese, with full width punctuation, and no line is cut off or left in English.
- [ ] With all four talk keys on, the menu says "按住右侧 Control 键、右侧 Option 键、右侧
  Command 键或地球仪（fn）键说话".
- [ ] The download lines read naturally, for example "正在下载语音模型：37%，共 2.47 GB".
- [ ] In a user account whose system language is Chinese and where Orra never had
  microphone access, the macOS prompt shows the Chinese explanation. The prompt is drawn
  by macOS, so it may follow the system language rather than Orra's own.
- [ ] With Orra's language set back to the system's (English first), everything is in
  English again.
- [ ] On a Mac with macOS 15.6, if one is at hand, English first and Chinese second shows
  English, and Chinese first shows Chinese.

Recording indicator and sounds, added on 2026-10-07, not verified yet:

- [ ] With a USB microphone chosen in Orra, start speaking right at the sound: the first
  syllable is in the text. The sound comes only once the microphone records.
- [ ] Hold the talk key in Notes: a moment after the press a short sound plays and a dark
  indicator appears at the bottom of the screen with the pointer: a small dark capsule with
  white bars that move with your voice, and no microphone or color. Notes keeps the focus:
  its text cursor still blinks, and the menu bar still shows Notes.
- [ ] A shortcut with the talk key, such as right Control+C in Terminal, plays no sound and
  shows no indicator, and neither does a quick tap of the key.
- [ ] Release: the bars settle into a slow, low wave, a second sound plays, and the
  indicator goes once the text is in Notes. The start sound does not show up as a word
  at the start of the text.
- [ ] Over a full screen app, on another Space, and on a second display with the pointer
  there, the indicator shows the same way.
- [ ] Clicks at the bottom of the screen pass through the indicator.
- [ ] Before the model is ready, a hold shows "The speech model is not ready. The Orra menu
  shows what is missing." in the indicator for a few seconds, and with microphone access
  off it shows "Microphone access is off". Dictating into a password field shows "Orra does
  not paste into password fields. Use Copy Last Dictation." Holding the key without
  speaking shows "No speech was recognized".
- [ ] In Settings, turning off "Show the recording indicator" and "Play sounds when
  recording starts and stops" takes effect at the next hold, and both stay off after
  quitting and reopening Orra.

Calmer recording indicator, added on 2026-10-10, not verified yet:

- [ ] While you hold the talk key, the Orra icon in the menu bar stays the plain mic, and
  macOS shows its orange microphone indicator in the menu bar. While Orra transcribes, the
  Orra icon stays the same too. If the icon showed a warning triangle from the last
  dictation, it turns into the plain mic when you press the key, since a new hold clears
  the last problem.
- [ ] With "Show the recording indicator" off in Settings, a dictation fills the Orra icon
  while you hold the key and turns it into a waveform after release until the text is
  pasted. Then it is the plain mic again.
- [ ] The capsule, the bars and the messages read well over a white page and over a dark
  window, in light and in dark mode.
- [ ] With Reduce Motion on (System Settings, Accessibility, Display), the bars hold a
  still, low wave while Orra transcribes instead of moving, and it looks different from
  the flat row of bars while you hold the key in silence.
- [ ] VoiceOver reads "Listening" while you hold the key, "Transcribing…" after release,
  and the message text when a dictation pastes nothing.

Idle bar, added on 2026-10-09, not verified yet:

- [ ] Once the model has loaded and Accessibility is on, a small dark bar with a light
  edge sits at the bottom center of the screen with the pointer, above the Dock, on light
  and dark backgrounds alike. Before that, while the welcome window asks for setup, there
  is no bar.
- [ ] With the Dock set to hide and show automatically, the Dock covers the bar when it
  slides up. Moving the pointer to another display moves the bar there.
- [ ] Holding the talk key turns it into the recording indicator, and it comes back after
  the paste or a message.
- [ ] With the pointer over the bar, "Hold right Control to talk" (or the chosen keys)
  shows above it, and goes when the pointer leaves. Clicks on the bar reach the window
  below it, and the app in front keeps the focus. While an Orra window such as Settings is
  in front, the hint may not show (a known limit).
- [ ] Over a full screen app and on another Space the bar shows too. Adding or removing a
  display, or moving the Dock, keeps it at the bottom.
- [ ] Turning off "Show a small bar at the bottom of the screen while Orra is ready" in
  Settings hides it at once, and it stays off after reopening Orra.

Personal vocabulary, added on 2026-10-08, not verified yet:

- [ ] Settings opens with a sidebar: General, Microphone, Vocabulary and About. Each page
  fits without scrolling, in English and in Chinese.
- [ ] Under Vocabulary, add a few names and terms that Orra got wrong before, with the field
  and Return or Add, and remove one with its minus button. Dictate sentences with them:
  they come out spelled as in the list.
- [ ] Dictate sentences without them: none of the listed words shows up.
- [ ] Hold the talk key without speaking: no listed word appears.
- [ ] The count above the list follows it, and the list is still there after
  quitting and reopening Orra.

Learning from corrections, added on 2026-10-08, not verified yet. Turn on Learn from my
corrections under Vocabulary in Settings first:

- [ ] Dictate a sentence with a name Orra gets wrong into Notes and fix the name by hand: a
  second or two after you stop typing, a notice above the recording indicator says the
  name was added to the vocabulary. A ring counts down the 10 seconds it stays. With the
  pointer over it the ring shows a pause sign, and after the pointer leaves it counts 4. The app you are in keeps the focus. The next dictation is more likely to
  write it right, and Orra never changes the text itself.
- [ ] Changing a word's meaning, such as 明天 to 后天 or Monday to Sunday, fixing one
  Chinese character as grammar such as 的 to 得, deleting words, or rewriting the sentence
  adds nothing. Fixing a word and then typing a period learns the word without the period.
- [ ] Dictate 我用通义千问写代码 so it comes out as 通一千问 and fix the one character: no
  word is added, and a notice asks "Add a word to your vocabulary?" with 通义千问 in its
  field. The app you are in keeps the focus and typing there still works while the notice
  shows. Click into the field, edit the word, and press Return or Add: the word is in the
  vocabulary and the focus is back in the app you were in. The ring counts down from the
  moment the notice appears, and pauses only while you edit. Click into the field, then
  click back into Notes without pressing Add: typing goes to Notes and the ring counts 4
  again. Close it, or let it run out, and the same fix does not offer it again for a week.
- [ ] Fill the vocabulary to 100 words, then add an offered
  word: the notice says the vocabulary is full and stays until it runs out. Make room and
  fix the same character again: the word is offered again.
- [ ] Dictate four lines with the same misheard name, switch to another app for a moment,
  come back and fix them within 3 minutes: one notice comes. Undo takes the name out of
  the vocabulary, and fixing it again, misheard any way, does not add it again.
- [ ] Fix a misheard name so it is learned, then remove it with the minus button under
  Vocabulary in Settings. Fix the same name again: it is added again and the notice with
  Undo shows.
- [ ] When a dictation comes out as 陈阳写的那些文档一样嘛, fix it to 晨阳写的那些文档一样吗:
  only the name 晨阳 is offered, never the whole sentence. Fix 通一千万 to
  通义千问: 通义千问 is learned, not 义千问.
- [ ] In an app whose text macOS cannot read, such as Sublime Text, the log says "the
  focused element is not a text field Orra can read" and nothing is learned. Copy the
  right word there: the Orra menu offers to add it to the vocabulary.
- [ ] In Messages or WeChat, fix a misheard name and press Return to send: the fix still
  counts. Click into another field during the watch: nothing is read from it.
- [ ] Dictating into a password field, or switching apps right after the paste, records
  nothing.
- [ ] With the setting off, nothing is recorded. Forget Learned Corrections deletes the
  pairs and keeps the vocabulary.
- [ ] Typing feels the same in the app you dictated into while Orra watches the field.

App icon, added on 2026-10-07, not verified yet:

- [ ] Finder, the Applications folder, the Accessibility list in System Settings and the
  welcome window show the violet icon with the white ring and bars, in light and dark
  mode.
- [ ] On a Mac with macOS 15.6, if one is at hand, Finder shows the same icon.

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

Dock icon, added on 2026-10-10, not verified yet:

- [ ] After launch Orra is in the Dock and in Command Tab, and still in the menu bar.
  Clicking the Dock icon opens Settings, or the welcome window while setup needs you.
- [ ] Turning off "Show Orra in the Dock" in Settings, General keeps the icon until the
  Settings window closes, then it goes. Opening Settings or the welcome window from the
  menu brings it back while the window is open. The choice stays after reopening Orra.
- [ ] Dictating into another app works the same with the icon shown, and the recording
  indicator never makes Orra the active app.

Filler removal, added on 2026-10-10, not verified yet:

- [ ] With "Remove filler words such as um and 呃" on, the default, dictate
  "呃，我明天下午要去趟医院" and "Um, I think we should push the launch". The pasted text
  has no 呃 and no Um, and the English sentence starts with a capital.
- [ ] Dictate "好啊，那就这么定了" and a bare "嗯嗯". Both paste as said.
- [ ] Turn the setting off in Settings, General: the same dictations keep their fillers.
  The choice stays after reopening Orra.

Numbers as digits, added on 2026-10-10, not verified yet:

- [ ] With "Write numbers as digits" on, the default, dictate "我下个月想去试驾 Lexus RX
  三五零" and "明天下午三点开会，预算三百五十块". The paste reads RX 350, 下午3点 and
  350块, with the space before 350 as the model wrote it.
- [ ] Dictate "我们一起去，三五成群" and "我买了三本书". Both paste as said.
- [ ] Turn the setting off in Settings, General: the numbers stay in Chinese characters.
  The choice stays after reopening Orra.

Updates from inside the app, added on 2026-10-10, not verified yet:

- [ ] A release DMG installs by dragging Orra to Applications and opens without a warning.
  The first launch reaches no network until you download the model.
- [ ] At the second launch Orra asks whether to check for updates automatically. Settings,
  About shows the answer and changes it.
- [ ] Check for Updates in the menu says Orra is up to date for the newest release, and
  offers the newer one with its notes from an older release. Installing it replaces Orra
  and opens the new version, which keeps Accessibility and the microphone.
- [ ] An update found by an automatic check does not come in front of the app you are in.
  The menu offers Install Orra with its version, and the update window shows once you
  switch to Orra. There is no checkbox to install updates automatically.

Interface language, added on 2026-10-10, not verified yet:

- [ ] Settings, General, Language offers Same as the Mac, English and 简体中文. Choosing one
  shows Restart Orra, and after the restart the menu, Settings, the welcome window and the
  indicator use that language. Same as the Mac follows System Settings again.
- [ ] Settings looks like System Settings: colored icons in the sidebar, a header with icon,
  title and summary on every page, and icons on the rows of General. Language is the first
  section of General. The window can be made larger, keeps its size, and cannot be made
  smaller than its content.

Report a Problem, added on 2026-10-10, not verified yet:

- [ ] Report a Problem… in the menu bar menu, and in the Help menu while Orra is in the
  Dock, opens the Report a Problem window. It shows the report after a few seconds.
- [ ] The report lists Orra's version, macOS, the Mac model and chip, the settings, the
  permissions and Orra's log from the last hour. It contains no dictated text, no
  vocabulary words or learned pairs, no clipboard, and neither your home folder path nor
  your account name. No permission prompt appears.
- [ ] The window has a title field, a What happened? text with a hint while empty, the
  Attach the diagnostic report checkbox, on at first, and Show the report, which shows
  the report text. Continue on GitHub stays off while the text is empty, and while the
  report is being created with the checkbox on. Command-Return chooses it, and Return
  starts a new line.
- [ ] Continue on GitHub opens the bug report form in the browser with the title, What
  happened, Orra version, macOS version and Mac model filled in. Without a title, the
  first line of the text is the title. Chinese text and emoji arrive as written.
- [ ] Signed out of GitHub, Continue on GitHub leads to the sign in page, and signing in
  leads back to the form with the text filled in. Creating a new account from there:
  note whether GitHub returns to the form afterwards.
- [ ] With the checkbox on, Finder selects Orra-Report-<date>.txt, and dragging it into
  the form attaches it. With the checkbox off, Finder does not open.
- [ ] The clipboard keeps what it held when you choose Continue on GitHub with a short
  text. Copy Report puts the report on the clipboard.
- [ ] A very long text, such as several pages, opens the form with the start of the text
  and the cut marker at its end, the window says the full text is on the clipboard,
  and pasting gives the whole text. Nothing is sent without you submitting the form.
- [ ] With the interface in Chinese, the menu item and the window read in Chinese.

## Not implemented

- A longer clipboard restore for remote desktop and virtual machine apps. The delay is
  0.5 seconds everywhere and needs a decision before it changes.
- A choice of model, a personal dictionary, and the onboarding that adapts to the user.
- Key combinations and mouse buttons as talk keys, and hands free mode.
- Rewriting with a model: spoken self corrections, fillers that need context such as 那个
  and like, and translation. Only the filler and number rules exist.
