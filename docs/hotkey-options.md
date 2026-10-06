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
  seconds later and removes the tap if access is gone. It never switches the tap back
  on without access.

Known risk: revoking Accessibility access while an active tap is installed can freeze
keyboard and mouse input. A September 2026 report reproduces it on macOS 15, 26 and
27 with the same kind of tap, and Apple has not given a workaround. [11] Orra removes
its tap when it learns that access is gone, which is not verified on hardware.
Removing Orra from the list may not be noticed at all, because `AXIsProcessTrusted` can
keep returning true. [12] Quit Orra before changing its Accessibility access.

Blind spots: chords the tap cannot see look like a plain hold. Volume, media and
brightness keys arrive as system defined events when "Use F1, F2, etc. keys as standard
function keys" is on, and no key down reaches the tap while secure input is on, for
example with Terminal's Secure Keyboard Entry or a focused password field. Fn itself
keeps working under secure input because it is a modifier (reported, not tried on this
Mac). A blind spot starts a recording. Holds without speech give no
text, and under secure input the text is left on the clipboard instead of pasted. With
right Control as the talk key, the likeliest case is a Control shortcut held for a while
in a terminal with Secure Keyboard Entry, which is then taken as a dictation if someone
is talking.

On 2026-10-05 the maintainer asked for a choice of keys with right Control as the
default, after the Fn key of a Logitech MX Keys did not reach Orra at all. Implemented in
`Orra/TalkKey.swift` and `Orra/TalkKeyDetector.swift`:

- The user turns on one or more of right Control, right Option, right Command and fn,
  under Talk Key in the menu or in the Settings window. The last key that is on stays on.
  The choice is saved in UserDefaults.
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
- Left modifiers and Shift are not offered. The left ones are part of many shortcuts,
  so a recording would start on each of them, and Shift on its own switches Chinese input
  methods between Chinese and English.

Not done yet: key combinations and mouse buttons as talk keys, hands free mode, and
moving the tap off the main thread.

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

SDK references: `HIToolbox/CarbonEvents.h` (hot key API and event kinds), `HIToolbox/Events.h`
(`kVK_Function`), `AppKit/NSEvent.h` (global monitor comment, `isARepeat`,
`NSEventModifierFlagFunction`), `CoreGraphics/CGEventTypes.h` and `CGEvent.h` (tap options,
disabled reasons, `CGEventTapEnable`, listen access functions), `HIServices/AXUIElement.h`
(`AXIsProcessTrustedWithOptions`).
