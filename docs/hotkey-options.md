# Global hotkey options for push to talk

Orra needs two events from the push to talk key, system wide and while another app
is frontmost: the key went down, and the key came up. This note compares the ways
to get those events on macOS 15 and later and the permission each one needs.
The maintainer chose option 3 on 2026-10-03, see the next section.

Facts marked "SDK" were checked in the macOS 27.0 SDK headers that ship with
Xcode 27.0 on this machine, by reading the header or by compiling a snippet
against it. Facts marked "reported" come from developer reports, not from Apple.

## Decision

On 2026-10-03 the maintainer chose option 3, an active event tap at the session level,
with holding Fn on its own as the push to talk key. The tap needs Accessibility, which
Orra needs anyway to paste, and holding a modifier on its own types nothing into the
app in front.

Implemented on 2026-10-04 in `Orra/FnKeyDetector.swift` (now `Orra/TalkKeyDetector.swift`)
and `Orra/HotkeyTap.swift`:

- Holding Fn alone starts a hold and releasing it ends the hold. Fn's own events are
  swallowed, so the "Press fn key to" action should not also fire. Not verified yet.
- Any other key or modifier during a hold cancels it, so Fn+Delete and Fn+arrows keep
  working.
- Fn pressed while Shift, Control, Option or Command is held is left alone.
- When the system reports a change to the Accessibility list, Orra checks again two
  seconds later and removes the tap if access is gone.
- When the system switches the tap off, after a slow callback
  (`kCGEventTapDisabledByTimeout`) or on certain user input
  (`kCGEventTapDisabledByUserInput`), Orra removes the tap at once, and the menu and the
  icon show the talk key as off. Two seconds later it tries a new tap the same way as at
  launch, and the system refuses a new tap without access. Since 2026-10-06 it never
  switches such a tap back on, see the known risk below.

Known risk: revoking Accessibility access while an active tap is installed can freeze
keyboard and mouse input. A September 2026 report reproduces it on macOS 15, 26 and
27 with the same kind of tap, and Apple has not given a workaround. In that report no
tap disabled event arrived before input froze. [11] Orra removes its tap when it learns
that access is gone, which is not verified on hardware. Removing Orra from the list may
not be noticed at all, because `AXIsProcessTrusted` can keep returning true. [12] On
macOS 26.6.2 it answers from a cache inside the process, which only the
`com.apple.accessibility.api` distributed notification clears (read from the HIServices
binary on 2026-10-06).

A developer reports `kCGEventTapDisabledByTimeout` events again and again, and delayed
key presses, after access was revoked from a modifier key tap. [13] Until 2026-10-06
Orra switched its tap back on after such an event whenever `AXIsProcessTrusted` still
said yes, which could keep a tap without access in the path of every key press. Now it
removes the tap and tries a new one, and the system refuses a new tap without access
(reported, [12]). This cannot help when no such event arrives, as in [11]. None of this
is verified on hardware. Quit Orra before changing its Accessibility access.

Blind spots: chords the tap cannot see look like a plain hold. Volume, media and
brightness keys arrive as system defined events when "Use F1, F2, etc. keys as standard
function keys" is on, and no key down reaches the tap while secure input is on, for
example with Terminal's Secure Keyboard Entry or a focused password field. Fn itself
keeps working under secure input because it is a modifier (reported, not tried on this
Mac). A blind spot starts a recording. Holds without speech give no text. With right
Control as the talk key, the likeliest case is a Control shortcut held for a while in a
terminal with Secure Keyboard Entry, which is then taken as a dictation if someone is
talking, and its text is pasted at the prompt.

Pasting under secure input: until 2026-10-05 Orra left the text on the clipboard
whenever any process held secure input, without putting the old clipboard back. Secure
input is a single flag for the whole session, so a process that keeps it on in the
background, which is reported to happen, stopped every paste in every app. On
2026-10-05 the maintainer chose to paste as usual under secure input. Secure input keeps
other apps from reading keys, and posting Command V is reported to still work. Orra now
pastes and puts the old clipboard back, except where the text could land in a password
field, which turns secure input on while it has the focus. While secure input is on,
Orra asks Accessibility about the focused field of the app in front, right before the
paste, with at most two reads of half a second each:

- A password field (subrole AXSecureTextField) gets nothing, and the clipboard is left
  alone.
- A text field, text area or combo box gets the paste.
- A field Accessibility cannot describe gets nothing when the app in front holds secure
  input itself, and the paste otherwise. Some browsers show no elements of a web page
  until an assistive app asks for them, while they still turn secure input on for a
  password field, so such a field looks like this (reported).

The text stays under Copy Last Dictation, which marks it concealed and keeps it on this
Mac. Whether a posted Command V reaches an app that holds secure input, and how web
password fields report themselves, are not tried on this Mac yet.

On 2026-10-05 the maintainer asked for a choice of keys with right Control as the
default, after the Fn key of a Logitech MX Keys did not reach Orra at all. Implemented in
`Orra/TalkKey.swift` and `Orra/TalkKeyDetector.swift`:

- The user turns on one or more of right Control, right Option, right Command and fn,
  under Talk Key in the menu or in the Settings window. The last key that is on stays on.
  The choice is saved in UserDefaults. Since the second change of 2026-10-10 there is one
  talk key, see the end of this file.
- A right hand modifier is told from its left twin by the device dependent bit in the
  event flags (IOLLEvent.h), or by the shared flag on a keyboard that sets no such bits.
  Pressed while another modifier is held, left twin included, it starts no hold.
- Only fn's own events are swallowed. The right hand modifiers have no system action of
  their own, unless Dictation or Siri is set to a double press of that key, so their
  events pass through. While fn is not a talk key, its events pass through and its system
  action works as before.
- A mouse button press during a hold of a right hand modifier ends the hold, because a
  Control, Option or Command click is a shortcut of its own, such as a context menu. A
  global NSEvent monitor observes the clicks. It cannot delay them and needs no permission
  for mouse events. An fn hold goes on, because clicking into a field while holding fn is
  a plain click.
- On a keyboard that sets no left or right bits, the talk key's own event while it is
  down counts as its release, and a release while the left twin is still down ends the
  hold as a shortcut instead of transcribing it.
- Left modifiers and Shift were not offered. The left ones are part of many shortcuts,
  so a recording would start on each of them, and Shift on its own switches Chinese input
  methods between Chinese and English. Since 2026-10-10 the left modifiers are offered,
  see below. Shift is still not.

On 2026-10-10 the maintainer approved more talk keys, choosing the key by pressing it,
and a hands free mode like Wispr Flow's, after a user found right Control awkward while
the right hand is on the mouse. Implemented in `Orra/TalkKey.swift`,
`Orra/TalkKeyDetector.swift`, `Orra/HotkeyTap.swift` and
`Orra/PushToTalkStateMachine.swift`:

- Left Control, left Option and left Command can be talk keys. Their raw values are new,
  and the saved values of the earlier keys did not change, so existing choices load as
  before. Shift is still not offered.
- A left modifier starts nothing at its press. Only once it has been held alone for
  `TalkKeyDetector.leftKeyDelay` (0.3 seconds) does the recording start and the cue
  play. Any other key, modifier or click before that turns the press into a shortcut
  with no cue, and every event passes through, so Command C, Command Tab and Control
  click keep working. Speech in that first moment is not recorded. The right modifiers
  and fn start at the press as before.
- The welcome window has a step "Choose your talk key", and Settings, General has a
  "Press a Key…" button. The next modifier press becomes the only talk key. Shift and
  other keys leave a note, Escape stops. The tap reports those presses instead of
  detecting holds, but only while Orra is the active app, and it swallows fn so its system
  action does not fire. Without Accessibility access an NSEvent local monitor sees Orra's
  own key events, which needs no permission. No new permission is asked for. Since the
  second change of 2026-10-10 a recorder field takes the place of the button, see below.
- The welcome step recommends fn when the Mac has a built in keyboard with the lid open,
  and right Control otherwise. It reads the IOKit registry for an IOHIDDevice marked
  Built-In with the keyboard usage (page 1, usage 6), as `ioreg` showed on a MacBook on
  2026-10-10. Reading the registry needs no permission, unlike opening the device with
  IOHIDManager, which needs Input Monitoring. It is not a documented interface, so the
  step names both recommendations.
- Hands free: a press released within `tapLimit` (0.3 seconds) is a tap. Its recording
  goes on for `doublePressWindow` (0.4 seconds). A second press of the same key on its
  own within the window is a hold under the usual rules: a left modifier waits for
  `leftKeyDelay`, and a key or click while it is down makes it a shortcut that records
  nothing and plays no cue, so a tap of Command followed by Command V never starts a
  dictation. Only when the second press is released within `tapLimit` too does the
  recording become a hands free dictation, so the first words are not lost to a restart
  of the microphone. A longer second press is an ordinary hold that pastes at its
  release, so a brushed key followed by a hold never leaves Orra recording. For a left
  modifier the tap never recorded, so the double press starts the recording at the second
  release. A second press after the window is an ordinary hold. A key, modifier or click
  inside the window ends it, and a press of another talk key starts that key's own hold.
- During a hands free dictation the indicator shows "Press <key> to finish". The next
  press of that key on its own ends the dictation at its release and pastes. A release is
  used rather than the press, so a shortcut with the key, such as Command Tab, does not
  end it. Typing and clicks otherwise leave the dictation alone. Escape cancels it
  without pasting. Escape is swallowed only while a hands free dictation runs, and its key
  up passes through, because the tap does not watch key ups. Changing the talk keys so
  that the key is no longer one cancels the dictation. The recording stops at the limit,
  60 seconds at first and 5 minutes since 2026-10-17, and pastes, with a message that
  says why. Since then the next press of the key, until that message goes 30 seconds
  after it shows, only clears it, because it was meant to stop the recording that the
  limit already stopped. The same holds in Press to start and stop and in Double press.
  In Hold mode, where holding the key is how one dictates, that press waits as a left
  hand key does: released sooner it only clears the message, and held longer it is a
  hold as usual, which keeps the speech of the wait. A quick double press then still
  starts hands free.
- The controller tells the tap when no hands free dictation runs, for example after the
  limit or when a double press came while the previous dictation was still being
  transcribed, so Escape is never kept from the app by mistake.
- The Dictation block of Settings, General (Advanced… before 2026-10-13, the Dictation page
  before that, General at first) and the Talk Key menu have a switch "Double press for
  hands free", on by default. While it is off, a short press is a hold as before.
- Hold to talk is unchanged for the right modifiers and fn. A quick tap still records
  nothing that reaches the model.

Not verified on hardware yet: whether the 0.3 and 0.4 second values feel right, whether
the macOS Dictation shortcut "Press Control Key Twice" or a Siri double press of Command
fire as well when a double press of that key is used, and whether the registry check finds
the keyboard of an Intel MacBook.

Later on 2026-10-10 the maintainer found the talk key switches confusing, several keys on
at once included, and asked for one key that the user sets by pressing it, with the
names keyboards print on the keys. Implemented in `Orra/TalkKey.swift`,
`Orra/KeyName.swift`, `Orra/PushToTalkController.swift`, `Orra/HotkeyTap.swift`,
`Orra/SettingsView.swift`, `Orra/WelcomeView.swift` and `Orra/StatusMenu.swift`:

- There is one talk key. `TalkKeyPreference` still saves it under `talkKeys`, as a list
  of one, so Orra 0.1.0 reads it after a downgrade. A saved list of several keys, from
  0.1.0 or an earlier build of this branch, keeps one by `TalkKey.keepOrder`: fn, right
  Control, right Option, right Command, left Control, left Option, left Command. fn comes
  first because right Control is the default, so a user who turned fn on chose it on
  purpose. The detector and the tap still take a set of keys, which now holds one.
- Settings, General (Dictation from 2026-10-12 to 2026-10-13) shows a recorder field like
  the shortcut recorders of Mac apps. It shows the key with its symbol and Mac name, such as "⌥ Right
  Option", and a small hint with the label of other keyboards: Alt for Option and Windows
  key for Command, which a keyboard with a Windows layout prints on the keys macOS uses as
  Option and Command, and Globe 🌐 for fn. Control needs none. Clicking the field or
  Change… starts recording, and the line under it says "Use fn, Control, Option or Command
  on its own. Escape cancels." A line under the field recommends fn on a Mac's built in
  keyboard and right Control on an external one.
- `KeyRecorder` decides. A key that can be a talk key counts when it goes down on its own
  and comes up again with nothing pressed in between, so Command C is never taken for
  Command, and the tap needs no special case for the release of the chosen key. Anything
  else is turned down with a reason under the field: Shift (it switches input methods),
  Caps Lock (it is a lock and switches input methods too), a combination (two keys, or a
  modifier pressed while another is held), or a key that types or acts, named by
  `KeyName`, such as "The Return key" or "The A key". A combination names its keys with
  the modifier symbols, such as "⌘ C is a key combination", and fn only when it was
  pressed, because arrow keys carry the Fn flag on their own. The letter comes from the
  current ASCII capable keyboard layout through UCKeyTranslate, which reads the layout
  and needs no permission. The note stays until a key that can be the talk key goes down,
  and VoiceOver reads it out, as it reads the prompt when recording starts. Recording
  goes on until a key is chosen, Escape, a click anywhere in Orra or a switch to another
  app. The key names are shown on screen only, never logged.
- While recording, the tap swallows fn's events and every key down, but only while Orra
  is the active app, so a key pressed to record types nothing and Escape does not close
  the window. Other modifiers pass through, so apps keep an accurate picture of which
  are down. That is why a Shift press still switches Pinyin between Chinese and English,
  and Caps Lock still toggles, while recording. Without Accessibility access a local
  NSEvent monitor does the same for Orra's own events.
- The welcome step shows the same recorder field, with the Use fn or Use right Control
  button under the recommendation.
- Talk Key in the menu is a line with the key, such as "Talk Key: ⌥ Right Option (Alt)",
  and Change Talk Key…, which opens Settings on General (on Dictation from 2026-10-12 to
  2026-10-13). A menu cannot record a key
  press. The hands free switch stays there.

Not verified on hardware yet: how the recorder feels, whether a Windows layout keyboard
reports its Alt and Windows keys as Option and Command as expected, and the key names on
layouts other than ABC.

Not done yet: key combinations and mouse buttons as talk keys, and moving the tap off the
main thread.

On 2026-10-13 the maintainer asked for a second key for translation, with a default the
user can change. Implemented in `Orra/TalkKey.swift`, `Orra/TalkKeyDetector.swift`,
`Orra/HotkeyTap.swift`, `Orra/PushToTalkController.swift` and `Orra/SettingsView.swift`:

- The translation key is right Option by default, or right Command when the talk key is
  right Option. `TranslationKeyPreference` saves it under `translationKey` once the user
  picks it, or once picking the talk key moved it. Until then it follows the talk key by
  that rule. A saved key equal to the talk key, which Orra never writes, loads as the
  default.
- The two keys are never the same. Picking for one key the key the other one has swaps
  them, saves both, and a note under the recorder says "The two keys swapped. The talk
  key is now right Option and the translation key right Control." (两个键已互换。现在说话键是右侧
  Option 键，翻译键是右侧 Control 键。) VoiceOver reads the note. It goes when the user records a
  key again. The welcome window's recorder records the talk key, so it swaps the same way.
- The tap watches the translation key only while translation is on. The detector and the
  tap still take a set of keys, which then holds two.
- The translation key waits `TalkKeyDetector.leftKeyDelay` (0.3 seconds) before its
  press counts, whichever key it is, by the mechanism of the left hand keys: the detector
  takes a set of delayed keys, and a press of one is `arming` until the timer fires. Any
  other key, modifier or click during the wait makes the press a shortcut that plays no
  cue and passes every event through, so Option E and the other characters right Option
  types, and shortcuts such as Option Command Escape, keep working. A hold longer than the
  wait that then meets another key is cancelled like any hold, and the key passes
  through. The talk key keeps its own rule: a right hand key or fn starts at once.
- Since 2026-10-16 a right hand key or fn that waits, the translation key or a key inside
  another watched combination, starts the microphone at its key down (event `armed`,
  state `arming`), silently: no cue, no sound and no message. When the press counts, that
  recording becomes the dictation, so it starts at the key down. The shortest dictation,
  `RecordingLimits.minimumHold`, still counts from the moment the press counted, so a
  press of the key alone has to last as long as before to be transcribed. A shortcut, a
  click or a release before the wait is over drops it silently, and the samples are
  thrown away.
  A press dropped before its start began never starts the microphone, so quick
  shortcuts do not line up starts and stops in front of the next hold.
  Left hand keys and combinations of modifiers keep the old rule and record nothing while
  they wait, because they are part of so many shortcuts that the microphone indicator
  would flash at each one. A press in double press mode records nothing at its press
  anyway. The indicator may still flash for a shortcut with right Option.
- Hands free works the same for both keys, under the one switch "Double press for hands
  free". A double press of the translation key records hands free, the indicator says
  "Press right Option to finish", and the next press of that key alone pastes the
  translation. Its tap's recording is dropped at the tap's release, and the second press
  records from its key down. A left hand key's tap never recorded, so its double press
  starts the recording at the second release. A press of the other key during a hands free
  dictation is ignored, as any other modifier.
- A tap of the talk key followed within the double press window by the translation key
  drops the tap's recording, and the translation key records after its own wait, without
  starting at its key down, because one event cannot both drop a recording and start one.
- Settings, General has a recorder field for the translation key under Keys, right after
  the talk key's. It is always shown and dimmed with "Turn on Translation under Features
  to use this key." while translation is off (a Translation page until 2026-10-13, then a
  row under the Translation switch until the sidebar came back).
  The notes about a press that cannot be the key name the translation key while it is
  recorded. Recording one key stops a recording of the other.
- The menu's Talk Key submenu shows the translation key with Change Translation Key…,
  and the menu says "Hold right Option to translate" under the hold hint, while
  translation is on.

Not verified on hardware yet: whether 0.3 seconds feels right on a right hand key, how
right Option behaves with input methods that use it, and whether a double press of right
Command or right Option fires a Siri or Dictation shortcut set to that key.

On 2026-10-15 the maintainer asked for a second talk key, because some external
keyboards, such as the Logitech MX Keys, never send fn to the Mac. Implemented in
`Orra/TalkKey.swift`, `Orra/PushToTalkController.swift`, `Orra/ExternalKeyboard.swift`,
`Orra/LearnedNotice.swift`, `Orra/AppDelegate.swift` and `Orra/SettingsView.swift`:

- The talk key stays as it was, a single key or a combination, saved under `talkKeys` and
  `talkKeyCombination`. The second key is a single key saved under `secondTalkKey`, never
  in the `talkKeys` list, where an older Orra would keep one key by its own order. An
  older Orra ignores it and keeps the talk key. None is the default.
- The second key is never the talk key or the translation key. Picking it as the talk key
  swaps the two talk keys, or removes the second key when the old talk key was a
  combination. Picking it as the translation key removes it.
- The tap watches it beside the talk key, in the talk key's mode. Hands free, cancelling
  and the translation key work as for the talk key. A hands free dictation ends with the
  key that started it. When the second key is one of the modifiers of a combination of
  another key, such as right Control beside ⌃ ⌥, it waits 0.3 seconds, so the combination
  can take over, as the talk key already did beside a translation combination. Since
  2026-10-16 it records from its key down while it waits. A combination that counts at once
  keeps that recording, and one that waits drops it.
- The menu, the idle bar and the welcome window say "Hold fn or right Control to talk".
  The Talk Key submenu adds "Second Key: ⌃ Right Control".
- Once, when the talk key uses fn, no second key is set, setup is complete, the welcome
  window is closed and an external keyboard is connected, at launch or later, a notice
  offers right Control as the second key, or right Option or right Command when right
  Control is taken. Orra tells an external keyboard from the built in one by registry
  properties alone: a HID device whose primary usage is Keyboard, not marked Built-In,
  on USB or Bluetooth, and not named Apple Internal. It follows connections with
  IOServiceAddMatchingNotification and never opens a device, so it needs no permission
  and never sees a key. Which keyboard a key press came from is not asked.

## What Orra needs

- Press and release, not just press. `PushToTalkStateMachine` is driven by both.
- Works while any app is frontmost, including when Orra has no window.
- Key repeat must be either absent or flagged. The state model drops flagged repeats.
- Preferably no permission beyond Accessibility, which Orra needs anyway for text injection.
- Preferably the hotkey types nothing into the frontmost app.

## Option 1: Carbon `RegisterEventHotKey` (key combination only)

How it works: register a virtual key code plus modifier flags, then receive
`kEventHotKeyPressed` and `kEventHotKeyReleased` through a Carbon event handler.

- SDK: still declared in `HIToolbox/CarbonEvents.h` in the macOS 27.0 SDK, available
  since 10.0, with no deprecation attribute. A test snippet compiles against the SDK.
- Permission: none. The KeyboardShortcuts package, which is built on this API, answers
  "No" to whether it causes permission dialogs. [1]
- Press and release: yes, two distinct event kinds. (SDK)
- Single modifier such as Fn: no. The modifiers argument may be zero since 10.3, which
  registers a bare key, but a modifier key cannot be the key itself. A developer reports
  on a forum that the Fn/Globe key "remains not a modifier as far as the system Hot Key
  API is concerned". [2]
- Typing side effects: the combination is consumed system wide, so the frontmost app
  does not see it. Registration is not exclusive by default: every app registered for
  the same combination is notified. (SDK)
- Key repeat: unknown whether the pressed event repeats while the keys are held. Needs a
  five minute experiment. The state model ignores a press while listening either way.
- Cost: C API, needs a small wrapper, no Swift overlay. Hot key matching happens inside
  WindowServer, which on 26.5 started filtering synthesized events before they reach
  Carbon hot key listeners. That affects simulated keystrokes, not real ones. [3]

## Option 2: `NSEvent.addGlobalMonitorForEvents` (any key, including a single modifier)

How it works: install a global monitor for `.keyDown`, `.keyUp` and `.flagsChanged`.

- Permission: Accessibility. Apple: "Key-related events may only be monitored if
  accessibility is enabled or if your application is trusted for accessibility access
  (see AXIsProcessTrusted)". [4] Request it with `AXIsProcessTrustedWithOptions` and
  `kAXTrustedCheckOptionPrompt`. (SDK)
- Press and release: yes. `keyDown` carries `isARepeat`. A modifier produces one
  `flagsChanged` event when it goes down and one when it goes up, with no repeat.
- Single modifier such as Fn: yes. Fn/Globe arrives as `flagsChanged` with key code 63
  (`kVK_Function`). Do not rely on the `.function` modifier flag alone. The header says it
  is "Set if any function key is pressed", so arrow and F keys set it too. (SDK)
- Typing side effects: cannot be prevented. Apple: "you cannot modify or otherwise
  prevent the event from being delivered to its original target application". [4]
  Holding a modifier alone types nothing, so this option pairs well with a single
  modifier and poorly with a combination that produces a character.
- Cost: least code of all options. Events arrive asynchronously. The handler is not
  called for events sent to Orra itself, so a local monitor is needed while a window of
  Orra has focus. [4]

## Option 3: `CGEvent.tapCreate` (any key, can swallow events)

How it works: create an event tap at `kCGSessionEventTap` for key down, key up and
flags changed, add it to a run loop, handle events in the callback.

- Permission: Apple: taps receive key events when the process runs as root or "Access
  for assistive devices is enabled", meaning Accessibility. [5] Reported, from a
  developer who tested it rather than from Apple: a `.listenOnly` tap prompts for Input
  Monitoring, a default tap prompts for Accessibility, and an app that already has
  Accessibility also has Input Monitoring. [6] `CGPreflightListenEventAccess` and
  `CGRequestListenEventAccess` exist since 10.15 for the Input Monitoring case. (SDK)
- Press and release: yes, same event types as option 2. Repeat is readable through the
  `kCGKeyboardEventAutorepeat` field. (SDK)
- Single modifier such as Fn: yes, through flags changed with key code 63, and the
  `kCGEventFlagMaskSecondaryFn` flag. (SDK)
- Typing side effects: an active tap can return nil from the callback to drop the event.
  This is the only option that sees a single modifier and can also keep a combination
  from reaching the frontmost app.
- Cost: most code. The system disables a tap whose callback is too slow
  (`kCGEventTapDisabledByTimeout`) or on certain user input
  (`kCGEventTapDisabledByUserInput`), and the app must call `CGEventTapEnable` again.
  (SDK) An active tap sits in the path of every keystroke, which is the most invasive
  choice for users and reviewers.

## Option 4: IOKit HID (`IOHIDManager`)

Raw reports from the keyboard. Needs Input Monitoring. More code than any option above
with no benefit for Orra. Not researched further and not recommended.

## Key combination versus holding a single modifier

| | Combination (for example Control+Option+Space) | Single modifier (Right Option, Right Command, Fn/Globe) |
|---|---|---|
| Comfort while speaking a long sentence | Several keys held at once | One key held |
| Mechanism | Option 1 with no permission, or option 2 or 3 | Option 2 or 3 only, needs Accessibility |
| Types into the frontmost app | Not with option 1 or an active tap. Yes with option 2 if the combo produces a character | No |
| Conflicts | App shortcuts using the same combo | Right Option types accented characters in many layouts. Fn/Globe has system actions, see below |
| Key repeat | Key down repeats, must be flagged | None, flags changed does not repeat |

Fn/Globe specifics. System Settings > Keyboard has a "Press fn key to" or "Press Globe
key to" menu. Apple documents the Change Input Source choice. [7] A secondary source
lists all four choices: Change Input Source, Show Emoji & Symbols, Start Dictation
(press twice), Do Nothing, and notes that holding the key also flips the function
row. [8] Apple also notes that choosing a Dictation shortcut may change this setting
automatically. [9] For Orra this means a user who picks Fn must set the menu to Do
Nothing, otherwise the system action fires alongside Orra. That forum thread quotes an
Apple deprecation note saying the Fn shortcut modifier is reserved for system
use. I did not find that note on Apple's site, so treat it as reported. [2]

## Caveats shared by every option

- Secure input. When a password field or Terminal's Secure Keyboard Entry turns on
  secure input, third party keyboard listeners stop receiving key presses, while
  modifier changes such as Fn still arrive. Reported by many users on a community
  forum, where `ioreg -l -w 0 | grep SecureInput` is given to show which process holds
  it. [10] Whether option 1 is affected is not verified. Orra detects the condition by
  reading kCGSSessionSecureInputPID.
- Lost releases. Sleep, screen lock, fast user switching or a secure input field opened
  mid hold can swallow the key up. The state model ignores a press while listening and
  a release without a press, so nothing breaks, but Orra would stay in listening until
  the next release. A listening timeout is a likely follow up.
- Mapping to the state model. Carbon pressed and released map to
  `.pressed(isRepeat: false)` and `.released`. Key down maps to
  `.pressed(isRepeat: event.isARepeat)` and key up to `.released`. For a modifier,
  compare the flags before and after each flags changed event and emit a press when the
  chosen modifier appears and a release when it disappears.

## Suggested default, for the maintainer to confirm or reject

Superseded by the decision at the top of this note. Kept for the record.

Start with option 2 and a single modifier hold. Orra needs Accessibility for text
injection regardless, so the permission is not new. It is the least code, it supports
both a single modifier and a combination, and it types nothing when the key is a
modifier. Move to option 3 only if swallowing a combination becomes necessary. Keep
option 1 in mind as the no permission path if a combination is ever preferred.

Decisions needed: which mechanism, which default key, and whether the hotkey must be
hidden from the frontmost app.

## Sources

1. KeyboardShortcuts README, FAQ on permission dialogs: https://github.com/sindresorhus/KeyboardShortcuts
2. Forum thread on Fn/Globe key behaviour in macOS 12: https://forum.keyboardmaestro.com/t/has-the-globe-fn-key-acquired-new-abilities-in-macos-12/24580
3. Blog post on synthesized events and Carbon hot keys on macOS 26.5: https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/
4. Apple, `addGlobalMonitorForEvents(matching:handler:)`: https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
5. Apple, `CGEvent.tapCreate`: https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)
6. Apple Developer Forums thread on Input Monitoring versus Accessibility for event taps (developer reports): https://developer.apple.com/forums/thread/122492
7. Apple, Write in another language on Mac (the Fn/Globe key menu): https://support.apple.com/guide/mac-help/mchlp1406
8. MacMost, The Mac FN (Globe) Key: https://macmost.com/the-mac-fn-globe-key-everything-it-can-do.html
9. Apple, Dictate messages and documents on Mac: https://support.apple.com/guide/mac-help/mh40584/mac
10. Community thread on secure input blocking event taps: https://www.1password.community/1password-at-work-58/secure-input-blocking-other-apps-event-taps-25015/index2.html
11. Apple Developer Forums, system input hang when Accessibility is revoked with an active event tap: https://developer.apple.com/forums/thread/844416
12. Apple Developer Forums, app hangs if accessibility changes while using a CGEventTap: https://developer.apple.com/forums/thread/735204
13. Apple Developer Forums, detecting revoked Accessibility for a modifier key event tap (developer report): https://developer.apple.com/forums/thread/744440

SDK references: `HIToolbox/CarbonEvents.h` (hot key API and event kinds), `HIToolbox/Events.h`
(`kVK_Function`), `AppKit/NSEvent.h` (global monitor comment, `isARepeat`,
`NSEventModifierFlagFunction`), `CoreGraphics/CGEventTypes.h` and `CGEvent.h` (tap options,
disabled reasons, `CGEventTapEnable`, listen access functions), `HIServices/AXUIElement.h`
(`AXIsProcessTrustedWithOptions`).
