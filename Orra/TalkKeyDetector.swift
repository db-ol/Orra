import CoreGraphics

/// Recognizes a hold of one of the user's talk keys on its own, and a quick double press
/// that starts a hands free dictation, and turns them into push to talk events. The keys
/// are modifiers: right Control by default, the other right and left Control, Option and
/// Command keys, or fn (Globe), or combinations, see below.
///
/// Pure logic with no event tap and no clock of its own. `HotkeyTap` feeds it every key
/// down, key up and flags changed event with the time it arrived, runs the timer that `timer`
/// asks for, and does what the returned decision says.
///
/// Decisions about holds:
/// - A modifier posts a flags changed event with its own key code when it goes down or up,
///   and a flag tells down from up. For fn that is the secondary Fn flag. For Control,
///   Option and Command it is the device dependent bit that tells right from left. On a
///   keyboard that sets no such bits, the key's own event while it is down is its release
///   (see `TalkKey.isDown(in:wasDown:)`), and a release while the twin is still down ends
///   the hold as a shortcut. The flag alone is not enough, because the system also sets
///   the Fn flag on arrow and function key events.
/// - A hold starts only when no other modifier is down. A talk key pressed while Shift,
///   Control, Option, Command or fn is held belongs to another shortcut, so its events pass
///   through untouched. For right Control that includes left Control. That covers rollover:
///   if Command is still down when the talk key goes down, there is no hold, even if
///   Command comes up right after. Caps Lock is a lock, not a held key, so it does not
///   count.
/// - A left hand modifier is part of many shortcuts, such as Command+C, so its hold starts
///   only once the key has been held alone for `leftKeyDelay`. Until then nothing records
///   and no cue plays, and any other key, modifier or click turns the press into a shortcut
///   silently and lets every event through. The right hand modifiers and fn start at once,
///   unless they are among `delayedKeys`, which wait the same way but record meanwhile, see
///   below. The translation key is one, so Option shortcuts and the characters right Option
///   types keep working.
/// - A right hand key or fn that waits captures early (event `.armed`), see
///   `capturesEarly(_:)`: the microphone starts silently at the key down, so the speech of
///   the wait is kept when the press counts (event `.pressed`, or `.doublePressed` at a
///   release that starts hands free). When the press turns out to be a shortcut, or ends
///   before it counts, the event is `.cancelled`, which drops the capture silently.
/// - Any other key going down, or another modifier changing, during a hold turns the hold
///   into a shortcut such as Fn+Delete (forward delete), Fn+arrows (Home, End, Page Up,
///   Page Down) or right Control+C. The hold is cancelled and the other key passes through
///   untouched. Another talk key counts as another modifier here.
/// - A mouse button going down during a hold of Control, Option or Command ends the hold
///   too, because a click with one of them is a shortcut of its own, such as a context
///   menu. HotkeyTap reports clicks through `cancelForClick()`. An fn hold goes on,
///   because clicking into a field while holding fn is a plain click.
/// - The press and release of an fn hold are swallowed, so the system action set under
///   "Press fn key to" in Keyboard settings, such as switching the input source, does not
///   also fire. Whether swallowing is enough on every Mac is not verified yet. Control,
///   Option and Command have no system action of their own, unless Dictation or Siri is set
///   to a double press of that key, so their events always pass through.
/// - Key code 179 is ignored. It is reported to be a Globe key code that arrives as a key
///   down, so it must not cancel a hold. Not verified on real hardware.
/// - Other keys are never swallowed, and neither are the events of a modifier that is not
///   a talk key, except Escape during a hands free dictation, see below.
/// - Chords the tap cannot see look like a plain hold: volume, media and brightness keys
///   when "Use F1, F2, etc. keys as standard function keys" is on, because they arrive as
///   system defined events, and any key while secure input is on, because the system then
///   withholds key downs from taps while modifier changes still arrive. With right Control
///   as the talk key, that makes a Control shortcut held for a while in a terminal with
///   Secure Keyboard Entry look like a dictation. Holds without speech give no text, see
///   DictationQualityTests.
///
/// Decisions about hands free, while `handsFreeEnabled` is on:
/// - A press released within `tapLimit` is a tap, not a hold. Its recording goes on for
///   `doublePressWindow` (event `.tapped`), and a second press of the same key on its own
///   may start within that window. That press is a hold like the first, under the same
///   rules: a right hand key or fn records at once (event `.pressed`, which keeps the
///   tap's recording), and a left hand key waits for `leftKeyDelay`. Any key, modifier or
///   click while it is down makes it a shortcut, which records nothing more and plays no
///   cue. Only when the second press is released within `tapLimit` does it start a hands
///   free dictation (event `.doublePressed`), which keeps the recording. A longer second
///   press is an ordinary hold that is processed at its release, so a tap followed by a
///   hold never leaves Orra recording. A left hand key released before `leftKeyDelay` has
///   not recorded, so its double press starts the recording at the second release. A
///   second press after the window is an ordinary hold. Any other key, modifier or click
///   inside the window ends it, so a tap followed by a shortcut is no double press. A
///   press of another talk key inside the window ends it too, and starts that key's own
///   hold.
/// - During a hands free dictation the key may come up. A later press of the same key on
///   its own ends the dictation and pastes at its release (event `.released`). A release is
///   used rather than the press, so a shortcut with the key, such as left Command+Tab,
///   never ends the dictation: a key, modifier or click before the release makes the press
///   a shortcut that passes through. Clicks and typing otherwise leave the dictation alone.
/// - Escape during a hands free dictation cancels it without pasting and is swallowed, and
///   so is its key up. At any other time Escape passes through.
/// - While hands free is off, a short press is a hold like any other, which the controller
///   discards as too short.
/// - When the recording limit stops a dictation that a press of its key was to finish, the
///   user may not have noticed and still press the key to stop, which would start a new
///   recording. So until the owner ends the wait, the next press of that key on its own
///   records nothing and only sends `.pressedAfterLimit` at its release, see
///   `stopAtLimit()`. A shortcut with the key, Escape and other talk keys work as usual.
///
/// Decisions about trigger modes, see TriggerMode. Each key has its own, and a key without
/// one holds. Double press for hands free applies to keys in hold mode only.
/// - Press to start and stop (`.toggle`): a press records as a hold does, and its release,
///   however long the press, turns the recording into a hands free dictation (event
///   `.doublePressed`). A left hand key released before `leftKeyDelay` starts it at the
///   release. The next press on its own ends it as above. A shortcut during the first press
///   cancels it, as it cancels a hold.
/// - Double press (`.doubleTap`): a press records nothing. Released within `tapLimit` it is
///   a tap, and a second tap within `doublePressWindow` starts a hands free dictation at its
///   release. A press held longer than `tapLimit` does nothing.
///
/// Decisions about combinations, see KeyCombination. Left and right count the same.
/// - Modifiers only, such as Control and Option, are down while exactly those modifiers
///   are, and act like a single modifier: any other key, modifier or click makes the press
///   a shortcut, and their events always pass through. Their modifiers going down one by
///   one, or up after a press, are no other input.
/// - With a regular key, such as Shift, Command and D, the press is the key down of D while
///   exactly Shift and Command are held, and the release is its key up or the release of
///   one of the modifiers. The key down, its repeats and its key up are swallowed whenever
///   they match, also while another key records, so the app in front never types the D.
///   D with other modifiers, or alone, passes through.
/// - A combination wins over a single key when both go down with one event. When one of
///   its own modifiers is a talk key that waits, such as right Control while the
///   translation key is Control and Option, the combination takes over once its last
///   modifier goes down before the wait is over.
nonisolated struct TalkKeyDetector: Equatable, Sendable {
    /// What the event tap should do with one event.
    nonisolated struct Decision: Equatable, Sendable {
        /// The push to talk event to send, if any.
        var event: PushToTalkStateMachine.Event?
        /// True to drop the event, so neither the system nor other apps see it.
        var swallow: Bool

        static let passThrough = Decision(event: nil, swallow: false)
    }

    nonisolated enum Phase: Equatable, Sendable {
        /// No talk key is down and no dictation runs hands free.
        case up
        /// A key that waits is down on its own, and `leftKeyDelay` has not passed yet. Nothing
        /// records, unless the press captures early, see `capturesEarly(_:)`.
        case arming(Hotkey)
        /// The key is held on its own. A push to talk hold is in progress.
        case holding(Hotkey)
        /// The key is still down but the hold was cancelled. For fn, its release is
        /// swallowed because its press was. If another modifier caused the cancel, apps
        /// that track flags changed events may think fn is still down until the next
        /// modifier change. That is cosmetic.
        case cancelled(Hotkey)
        /// The key went down as part of another shortcut. Its release passes through.
        case passingThrough(Hotkey)
        /// The key was tapped and is up. A second press within `doublePressWindow` that is
        /// released within `tapLimit` starts a hands free dictation. `recording` is true when the tap sent `.pressed`, so the
        /// end of the window has to cancel that recording.
        case tapped(Hotkey, recording: Bool)
        /// A hands free dictation runs and the key is up.
        case handsFree(Hotkey)
        /// A hands free dictation runs and the key is down. Its release ends the dictation
        /// when `finishes` is true: the press came on its own, and no key, modifier or
        /// click came since.
        case handsFreeKeyDown(Hotkey, finishes: Bool)
        /// The recording limit stopped a dictation that a press of the key was to finish,
        /// and the key is up. Its next press on its own records nothing, see `stopAtLimit()`.
        case stoppedAtLimit(Hotkey)
        /// The key is down after a stop at the recording limit. Its release sends
        /// `.pressedAfterLimit` when `dismisses` is true: the press came on its own, and no
        /// key, modifier or click came since.
        case stoppedAtLimitKeyDown(Hotkey, dismisses: Bool)

        /// The talk key this phase is about, if any.
        var key: Hotkey? {
            switch self {
            case .up: nil
            case .arming(let key), .holding(let key), .cancelled(let key), .passingThrough(let key),
                 .tapped(let key, _), .handsFree(let key), .handsFreeKeyDown(let key, _),
                 .stoppedAtLimit(let key), .stoppedAtLimitKeyDown(let key, _): key
            }
        }

        /// Whether the detector holds the key as down.
        var keyIsDown: Bool {
            switch self {
            case .up, .tapped, .handsFree, .stoppedAtLimit: false
            case .arming, .holding, .cancelled, .passingThrough, .handsFreeKeyDown, .stoppedAtLimitKeyDown: true
            }
        }

        /// Whether a hands free dictation runs.
        var isHandsFree: Bool {
            switch self {
            case .handsFree, .handsFreeKeyDown: true
            default: false
            }
        }
    }

    /// A timer the owner runs for the current phase. When it fires, the owner calls
    /// `timerFired(generation:)` with the generation it was started for.
    nonisolated enum Timer: Equatable, Sendable {
        /// A left hand key is waiting to become a hold.
        case leftKeyDelay
        /// A press of a key in double press mode is waiting to be a tap. Held longer, it is
        /// nothing.
        case tapLimit
        /// A tap is waiting for a second press.
        case doublePressWindow

        var duration: Duration {
            switch self {
            case .leftKeyDelay: TalkKeyDetector.leftKeyDelay
            case .tapLimit: TalkKeyDetector.tapLimit
            case .doublePressWindow: TalkKeyDetector.doublePressWindow
            }
        }
    }

    /// How long a left hand modifier has to be held on its own before recording starts.
    /// Shortcuts such as Command+C press the second key well within this, so they never
    /// record or play the start sound. Speech in this first moment is not recorded. A right
    /// hand key or fn among `delayedKeys` waits as long before its press counts, and
    /// records from its key down meanwhile, see `capturesEarly(_:)`.
    static let leftKeyDelay: Duration = .milliseconds(300)
    /// A press released sooner than this is a tap, the first half of a double press. It is
    /// as long as `RecordingLimits.minimumHold`, so a tap was always too short to transcribe.
    static let tapLimit: Duration = .milliseconds(300)
    /// How long after a tap's release the second press may come to start a hands free
    /// dictation. A slower second press is an ordinary hold.
    static let doublePressWindow: Duration = .milliseconds(400)
    static let globeKeyCode: Int64 = 179
    /// Escape, from HIToolbox Events.h.
    static let escapeKeyCode: Int64 = 0x35

    private(set) var keys: Set<Hotkey>
    /// Keys whose press counts only after `leftKeyDelay`, like the left hand keys, even on
    /// the right hand side. Only keys in `keys` count.
    private(set) var delayedKeys: Set<Hotkey>
    /// How each key starts a dictation, see TriggerMode. A key missing here holds.
    private(set) var modes: [Hotkey: TriggerMode]
    /// Whether a double press starts a hands free dictation, for keys in hold mode.
    private(set) var handsFreeEnabled: Bool
    private(set) var phase: Phase = .up {
        didSet {
            if phase != oldValue {
                generation &+= 1
            }
        }
    }
    /// Counts phase changes, so a timer started for an earlier phase does nothing.
    private(set) var generation = 0
    /// When the key of the current press went down, as the event tap saw it.
    private(set) var pressedAt: ContinuousClock.Instant?
    /// Whether the current press waited before it counted, for the timing log.
    private(set) var pressWaited = false
    /// Whether the press that is arming started the microphone at its key down. Read only
    /// while arming.
    private var isCapturingEarly = false
    /// Whether the current press came within a tap's window, so its quick release is a
    /// double press.
    private var isSecondPress = false
    /// The regular key whose key down was hidden, so its key up is hidden too.
    private var hiddenKeyCode: Int64?

    init(keys: Set<Hotkey>, delayedKeys: Set<Hotkey> = [], modes: [Hotkey: TriggerMode] = [:], handsFreeEnabled: Bool = true) {
        self.keys = keys
        orderedKeys = Self.ordered(keys)
        self.delayedKeys = delayedKeys
        self.modes = modes
        self.handsFreeEnabled = handsFreeEnabled
    }

    /// Whether a press of `key` waits for `leftKeyDelay` before it counts. Until then it
    /// records nothing, unless it captures early, see `capturesEarly(_:)`.
    func waitsBeforeRecording(_ key: Hotkey) -> Bool {
        key.waitsBeforeRecording || delayedKeys.contains(key)
    }

    /// Whether a press of `key` that waits starts the microphone at its key down, silently,
    /// so the recording starts there once the press counts. Only a single right hand key or
    /// fn that waits because it is among `delayedKeys`. A left hand key or a combination of
    /// modifiers is part of too many shortcuts, and starting the microphone for each would
    /// flash its indicator. A press in double press mode records nothing anyway.
    func capturesEarly(_ key: Hotkey) -> Bool {
        delayedKeys.contains(key) && key.single != nil && !key.waitsBeforeRecording && mode(of: key) != .doubleTap
    }

    /// How `key` starts a dictation.
    func mode(of key: Hotkey) -> TriggerMode {
        modes[key] ?? .hold
    }

    /// Whether a quick double press of `key` starts a hands free dictation.
    private func doublePressStartsHandsFree(_ key: Hotkey) -> Bool {
        switch mode(of: key) {
        case .hold: handsFreeEnabled
        case .doubleTap: true
        case .toggle: false
        }
    }

    /// The timer the current phase needs, if any.
    var timer: Timer? {
        switch phase {
        case .arming(let key): mode(of: key) == .doubleTap ? .tapLimit : .leftKeyDelay
        case .tapped: .doublePressWindow
        default: nil
        }
    }

    /// The keys in a fixed order: combinations first, so a combination wins over one of its
    /// own modifiers, then the single keys. Kept with `keys`, because the tap asks for every
    /// event.
    private var orderedKeys: [Hotkey] = []

    private static func ordered(_ keys: Set<Hotkey>) -> [Hotkey] {
        let combinations = keys.compactMap(\.combination).sorted { $0.savedValue < $1.savedValue }.map(Hotkey.combination)
        let singles = TalkKey.allCases.map(Hotkey.key).filter(keys.contains)
        return combinations + singles
    }

    /// Replaces the talk keys, the keys among them that wait, and their modes. Returns
    /// `.cancelled` when a hold, a tap's recording or a hands free dictation of a key that
    /// is no longer a talk key was in progress. A press under way keeps the wait it started
    /// with.
    mutating func setKeys(_ newKeys: Set<Hotkey>, delayedKeys newDelayedKeys: Set<Hotkey> = [], modes newModes: [Hotkey: TriggerMode] = [:]) -> PushToTalkStateMachine.Event? {
        keys = newKeys
        orderedKeys = Self.ordered(newKeys)
        delayedKeys = newDelayedKeys
        modes = newModes
        guard let active = phase.key, !newKeys.contains(active) else { return nil }
        return reset()
    }

    /// Turns double press for hands free on or off for keys in hold mode. Turning it off
    /// ends a tap's window and returns `.cancelled` when the tap was recording. A hands
    /// free dictation that runs already goes on until it is finished.
    mutating func setHandsFreeEnabled(_ on: Bool) -> PushToTalkStateMachine.Event? {
        handsFreeEnabled = on
        guard !on, case .tapped(let key, let recording) = phase, mode(of: key) == .hold else { return nil }
        phase = .up
        return recording ? .cancelled : nil
    }

    /// Decides what to do with one key down, key up or flags changed event that arrived at
    /// `now`.
    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, at now: ContinuousClock.Instant = .now) -> Decision {
        var decision = decide(type: type, keyCode: keyCode, flags: flags, at: now)
        switch type {
        case .keyDown where decision.swallow:
            hiddenKeyCode = keyCode
        case .keyDown where keyCode != Self.escapeKeyCode && matchesCombinationWithKey(keyCode: keyCode, flags: flags):
            // A combination with a regular key never types into the app in front, also
            // while another key records.
            decision.swallow = true
            hiddenKeyCode = keyCode
        case .keyUp where keyCode == hiddenKeyCode:
            hiddenKeyCode = nil
            decision.swallow = true
        default:
            break
        }
        return decision
    }

    private func matchesCombinationWithKey(keyCode: Int64, flags: CGEventFlags) -> Bool {
        orderedKeys.contains { $0.hasRegularKey && $0.signal(type: .keyDown, keyCode: keyCode, flags: flags, isDown: false) == .down }
    }

    private mutating func decide(type: CGEventType, keyCode: Int64, flags: CGEventFlags, at now: ContinuousClock.Instant) -> Decision {
        switch type {
        case .flagsChanged, .keyUp:
            break
        case .keyDown where keyCode != Self.globeKeyCode:
            break
        default:
            return .passThrough
        }
        if case .tapped(let tapped, let recording) = phase,
           let other = orderedKeys.first(where: { $0 != tapped && $0.signal(type: type, keyCode: keyCode, flags: flags, isDown: false) == .down }) {
            // Another talk key ends the tap's window and starts a press of its own. Its
            // hold keeps the tap's recording. When it starts no recording at its press,
            // the tap's recording is discarded.
            phase = .up
            var decision = handleChange(of: other, isDown: true, type: type, flags: flags, at: now)
            if recording {
                switch decision.event {
                case nil:
                    decision.event = .cancelled
                case .armed:
                    // One event cannot drop the tap's recording and start another, so this
                    // press waits without an early capture.
                    decision.event = cancelEarlyCapture()
                default:
                    break
                }
            }
            return decision
        }
        if case .stoppedAtLimit(let stopped) = phase,
           let other = orderedKeys.first(where: { $0 != stopped && $0.signal(type: type, keyCode: keyCode, flags: flags, isDown: false) == .down }) {
            // Another talk key ends the wait and starts a press of its own.
            phase = .up
            return handleChange(of: other, isDown: true, type: type, flags: flags, at: now)
        }
        guard let active = phase.key else {
            // Only a press counts while no key is down. A release without a press, for
            // example of a key held since before launch, passes through.
            if let key = orderedKeys.first(where: { $0.signal(type: type, keyCode: keyCode, flags: flags, isDown: false) == .down }) {
                return handleChange(of: key, isDown: true, type: type, flags: flags, at: now)
            }
            return .passThrough
        }
        switch active.signal(type: type, keyCode: keyCode, flags: flags, isDown: phase.keyIsDown) {
        case .down:
            return handleChange(of: active, isDown: true, type: type, flags: flags, at: now)
        case .up:
            return handleChange(of: active, isDown: false, type: type, flags: flags, at: now)
        case .ignore:
            return .passThrough
        case .other:
            let droppedEarlyCapture = phase == .arming(active) && isCapturingEarly
            let decision = otherInput(isEscape: type == .keyDown && keyCode == Self.escapeKeyCode)
            // A combination that one of its own modifiers began, such as Control and Option
            // after a press of right Control that waited, takes over once nothing records.
            // An early capture of that modifier has not counted yet either.
            switch phase {
            case .passingThrough, .cancelled:
                guard decision.event == nil || droppedEarlyCapture,
                      let combination = orderedKeys.first(where: { $0.combination != nil && $0 != active && $0.signal(type: type, keyCode: keyCode, flags: flags, isDown: false) == .down }) else {
                    return decision
                }
                phase = .up
                var takeover = handleChange(of: combination, isDown: true, type: type, flags: flags, at: now)
                if droppedEarlyCapture {
                    switch takeover.event {
                    case .pressed:
                        // The combination counts at once and keeps the capture, which began
                        // at the key down of its first modifier.
                        break
                    case .armed:
                        // The capture goes on as the combination's own.
                        takeover.event = nil
                    default:
                        takeover.event = .cancelled
                    }
                }
                return takeover
            default:
                return decision
            }
        }
    }

    /// The timer for `generation` fired. Turns a left hand key held long enough into a hold,
    /// or ends a tap's window. Returns the event to send, if any.
    mutating func timerFired(generation: Int) -> PushToTalkStateMachine.Event? {
        guard generation == self.generation else { return nil }
        switch phase {
        case .arming(let key) where mode(of: key) == .doubleTap:
            // Held too long to be a tap. A hold does nothing in this mode. The mode can
            // have changed during the press, so an early capture is dropped.
            isSecondPress = false
            phase = .cancelled(key)
            return isCapturingEarly ? .cancelled : nil
        case .arming(let key):
            // Held long enough to be a hold, even when it was a second press.
            isSecondPress = false
            phase = .holding(key)
            return .pressed(isRepeat: false)
        case .tapped(_, let recording):
            phase = .up
            return recording ? .cancelled : nil
        default:
            return nil
        }
    }

    /// A mouse button went down. Ends a hold of a key that modifies clicks, see
    /// `TalkKey.modifiesClicks`, and returns `.cancelled` then. Turns a key that waits for
    /// its delay into a shortcut, which drops an early capture, ends a tap's window, and
    /// keeps a press during a hands free dictation from finishing it.
    mutating func cancelForClick() -> PushToTalkStateMachine.Event? {
        switch phase {
        case .holding(let key) where key.modifiesClicks:
            phase = .cancelled(key)
            return .cancelled
        case .arming(let key):
            phase = .passingThrough(key)
            return isCapturingEarly ? .cancelled : nil
        case .tapped(_, let recording):
            phase = .up
            return recording ? .cancelled : nil
        case .handsFreeKeyDown(let key, true) where key.modifiesClicks:
            phase = .handsFreeKeyDown(key, finishes: false)
            return nil
        case .stoppedAtLimitKeyDown(let key, true) where key.modifiesClicks:
            phase = .stoppedAtLimitKeyDown(key, dismisses: false)
            return nil
        default:
            return nil
        }
    }

    /// The owner tells that no hands free dictation runs, because it ended some other way,
    /// such as the recording limit, a microphone that failed, or a double press that came
    /// while the previous dictation was still being transcribed. Escape then passes
    /// through again, and a key that is down finishes nothing at its release.
    mutating func endHandsFree() {
        switch phase {
        case .handsFree:
            phase = .up
        case .handsFreeKeyDown(let key, _):
            phase = .cancelled(key)
        default:
            break
        }
    }

    /// The owner tells that the recording limit stopped the dictation of the current press
    /// or hands free dictation. When a press of the key was to finish it, after a hands free
    /// dictation or the first press in Press to start and stop that is still down, that
    /// press is still to come. Until `endLimitWindow()`, the next press of the key on its
    /// own then records nothing and sends `.pressedAfterLimit` at its release. A press that
    /// is down already counts as that press when it was to finish the dictation. Returns
    /// whether the key waits for that press. A hold in Hold mode finishes nothing at its
    /// release, so it stays as it is.
    mutating func stopAtLimit() -> Bool {
        switch phase {
        case .handsFree(let key):
            phase = .stoppedAtLimit(key)
        case .handsFreeKeyDown(let key, let finishes):
            phase = .stoppedAtLimitKeyDown(key, dismisses: finishes)
        case .holding(let key) where mode(of: key) == .toggle:
            phase = .stoppedAtLimitKeyDown(key, dismisses: false)
        default:
            return false
        }
        return true
    }

    /// The owner ends the wait for the press after a stop at the recording limit. A key
    /// that is down then finishes nothing at its release.
    mutating func endLimitWindow() {
        switch phase {
        case .stoppedAtLimit:
            phase = .up
        case .stoppedAtLimitKeyDown(let key, _):
            phase = .cancelled(key)
        default:
            break
        }
    }

    /// Forgets the current hold, for when the tap was off and may have missed events, or
    /// the key stopped being a talk key. Returns `.cancelled` when a recording was in
    /// progress, also an early capture.
    mutating func reset() -> PushToTalkStateMachine.Event? {
        defer {
            phase = .up
            pressedAt = nil
        }
        switch phase {
        case .holding, .handsFree, .handsFreeKeyDown, .tapped(_, recording: true):
            return .cancelled
        case .arming:
            return isCapturingEarly ? .cancelled : nil
        case .up, .cancelled, .passingThrough, .tapped(_, recording: false), .stoppedAtLimit, .stoppedAtLimitKeyDown:
            return nil
        }
    }

    private mutating func handleChange(of key: Hotkey, isDown: Bool, type: CGEventType, flags: CGEventFlags, at now: ContinuousClock.Instant) -> Decision {
        let swallow = key.swallows(type)
        let alone = key.isAlone(with: flags)
        switch (phase, isDown) {
        case (.up, true):
            isSecondPress = false
            guard alone else {
                phase = .passingThrough(key)
                return .passThrough
            }
            pressedAt = now
            if waitsBeforeRecording(key) || mode(of: key) == .doubleTap {
                return Decision(event: arm(key), swallow: swallow)
            }
            phase = .holding(key)
            pressWaited = false
            return Decision(event: .pressed(isRepeat: false), swallow: swallow)
        case (.arming, false):
            // Released before the delay. A press to start in toggle mode and the second press
            // of a double press count, and keep an early capture. Anything else counted
            // nothing and drops it, also a first tap that may still become a double press.
            let dropped: PushToTalkStateMachine.Event? = isCapturingEarly ? .cancelled : nil
            guard !key.twinIsDown(atReleaseWith: flags) else {
                phase = .up
                return Decision(event: dropped, swallow: swallow)
            }
            if mode(of: key) == .toggle || (isSecondPress && doublePressStartsHandsFree(key)) {
                phase = .handsFree(key)
                return Decision(event: .doublePressed, swallow: swallow)
            }
            guard doublePressStartsHandsFree(key) else {
                phase = .up
                return Decision(event: dropped, swallow: swallow)
            }
            phase = .tapped(key, recording: false)
            return Decision(event: dropped, swallow: swallow)
        case (.holding, false):
            if key.twinIsDown(atReleaseWith: flags) {
                phase = .up
                return Decision(event: .cancelled, swallow: swallow)
            }
            if mode(of: key) == .toggle {
                // The recording goes on after the press that started it.
                phase = .handsFree(key)
                return Decision(event: .doublePressed, swallow: swallow)
            }
            if doublePressStartsHandsFree(key), let pressedAt, pressedAt.duration(to: now) < Self.tapLimit {
                if isSecondPress {
                    phase = .handsFree(key)
                    return Decision(event: .doublePressed, swallow: swallow)
                }
                phase = .tapped(key, recording: true)
                return Decision(event: .tapped, swallow: swallow)
            }
            phase = .up
            return Decision(event: .released, swallow: swallow)
        case (.tapped(_, let recording), true):
            guard alone else {
                phase = .passingThrough(key)
                return Decision(event: recording ? .cancelled : nil, swallow: false)
            }
            // The second press. Only its release tells a double press from a hold, and a
            // key or click before then makes it a shortcut.
            pressedAt = now
            isSecondPress = true
            if waitsBeforeRecording(key) || mode(of: key) == .doubleTap {
                // A left hand key's tap never recorded, see `tapLimit`.
                let armed = arm(key)
                return Decision(event: recording ? cancelEarlyCapture() : armed, swallow: swallow)
            }
            phase = .holding(key)
            pressWaited = false
            return Decision(event: .pressed(isRepeat: false), swallow: swallow)
        case (.handsFree, true):
            pressedAt = now
            phase = .handsFreeKeyDown(key, finishes: alone)
            return Decision(event: nil, swallow: swallow)
        case (.handsFreeKeyDown(_, let finishes), false):
            guard finishes, !key.twinIsDown(atReleaseWith: flags) else {
                phase = .handsFree(key)
                return Decision(event: nil, swallow: swallow)
            }
            phase = .up
            return Decision(event: .released, swallow: swallow)
        case (.stoppedAtLimit, true):
            phase = .stoppedAtLimitKeyDown(key, dismisses: alone)
            return Decision(event: nil, swallow: swallow)
        case (.stoppedAtLimitKeyDown(_, let dismisses), false):
            guard dismisses, !key.twinIsDown(atReleaseWith: flags) else {
                phase = .stoppedAtLimit(key)
                return Decision(event: nil, swallow: swallow)
            }
            phase = .up
            return Decision(event: .pressedAfterLimit, swallow: swallow)
        case (.cancelled, false):
            phase = .up
            return Decision(event: nil, swallow: swallow)
        case (.passingThrough, false):
            phase = .up
            return .passThrough
        case (.up, false), (.passingThrough, true), (.tapped, false), (.handsFree, false), (.stoppedAtLimit, false):
            // A release without a press, for example a key held since before launch, or a
            // repeated press that belongs to another shortcut.
            return .passThrough
        case (.arming, true), (.holding, true), (.cancelled, true), (.handsFreeKeyDown, true), (.stoppedAtLimitKeyDown, true):
            // A repeated press while the key is already down. Keep fn's events, and the
            // regular key of a combination, hidden.
            return Decision(event: nil, swallow: swallow)
        }
    }

    /// Starts the wait of a press of `key`. Returns `.armed` when the press captures early.
    private mutating func arm(_ key: Hotkey) -> PushToTalkStateMachine.Event? {
        phase = .arming(key)
        pressWaited = true
        isCapturingEarly = capturesEarly(key)
        return isCapturingEarly ? .armed : nil
    }

    /// Lets the press that is arming wait without an early capture, for when a recording
    /// has to be cancelled first. Returns that `.cancelled`.
    private mutating func cancelEarlyCapture() -> PushToTalkStateMachine.Event {
        isCapturingEarly = false
        return .cancelled
    }

    /// Another key went down, or another modifier changed.
    private mutating func otherInput(isEscape: Bool) -> Decision {
        switch phase {
        case .holding(let key):
            phase = .cancelled(key)
            return Decision(event: .cancelled, swallow: false)
        case .arming(let key):
            // A shortcut with a key that waits, such as Command+C. Nothing counted yet, and
            // an early capture is dropped.
            phase = .passingThrough(key)
            return Decision(event: isCapturingEarly ? .cancelled : nil, swallow: false)
        case .tapped(_, let recording):
            phase = .up
            return Decision(event: recording ? .cancelled : nil, swallow: false)
        case .handsFree where isEscape:
            phase = .up
            return Decision(event: .cancelled, swallow: true)
        case .handsFreeKeyDown(let key, _) where isEscape:
            phase = .cancelled(key)
            return Decision(event: .cancelled, swallow: true)
        case .handsFreeKeyDown(let key, true):
            phase = .handsFreeKeyDown(key, finishes: false)
            return .passThrough
        case .stoppedAtLimitKeyDown(let key, true):
            phase = .stoppedAtLimitKeyDown(key, dismisses: false)
            return .passThrough
        case .up, .cancelled, .passingThrough, .handsFree, .handsFreeKeyDown, .stoppedAtLimit, .stoppedAtLimitKeyDown:
            return .passThrough
        }
    }
}
