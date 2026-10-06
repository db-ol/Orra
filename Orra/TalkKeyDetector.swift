import CoreGraphics

/// Recognizes a hold of one of the user's talk keys on its own and turns it into push to
/// talk events. The keys are modifiers: right Control by default, right Option, right
/// Command, or fn (Globe).
///
/// Pure logic with no event tap. `HotkeyTap` feeds it every key down and flags changed
/// event and does what the returned decision says.
///
/// Decisions:
/// - A modifier posts a flags changed event with its own key code when it goes down or up,
///   and a flag tells down from up. For fn that is the secondary Fn flag. For the right
///   hand modifiers it is the device dependent bit that tells right from left. On a
///   keyboard that sets no such bits, the key's own event while it is down is its release
///   (see `TalkKey.isDown(in:wasDown:)`), and a release while the left twin is still down
///   ends the hold as a shortcut. The flag alone is not enough, because the system also
///   sets the Fn flag on arrow and function key events.
/// - A hold starts only when no other modifier is down. A talk key pressed while Shift,
///   Control, Option, Command or fn is held belongs to another shortcut, so its events pass
///   through untouched. For right Control that includes left Control. That covers rollover:
///   if Command is still down when the talk key goes down, there is no hold, even if
///   Command comes up right after. Caps Lock is a lock, not a held key, so it does not
///   count.
/// - Any other key going down, or another modifier changing, during a hold turns the hold
///   into a shortcut such as Fn+Delete (forward delete), Fn+arrows (Home, End, Page Up,
///   Page Down) or right Control+C. The hold is cancelled and the other key passes through
///   untouched. Another talk key counts as another modifier here.
/// - A mouse button going down during a hold of a right hand modifier ends the hold too,
///   because a Control, Option or Command click is a shortcut of its own, such as a
///   context menu. HotkeyTap reports clicks through `cancelForClick()`. An fn hold goes
///   on, because clicking into a field while holding fn is a plain click.
/// - The press and release of an fn hold are swallowed, so the system action set under
///   "Press fn key to" in Keyboard settings, such as switching the input source, does not
///   also fire. Whether swallowing is enough on every Mac is not verified yet. The right
///   hand modifiers have no system action of their own, unless Dictation or Siri is set
///   to a double press of that key, so their events always pass through.
/// - Key code 179 is ignored. It is reported to be a Globe key code that arrives as a key
///   down, so it must not cancel a hold. Not verified on real hardware.
/// - Other keys are never swallowed, and neither are the events of a modifier that is not
///   a talk key.
/// - Chords the tap cannot see look like a plain hold: volume, media and brightness keys
///   when "Use F1, F2, etc. keys as standard function keys" is on, because they arrive as
///   system defined events, and any key while secure input is on, because the system then
///   withholds key downs from taps while modifier changes still arrive. With right Control
///   as the talk key, that makes a Control shortcut held for a while in a terminal with
///   Secure Keyboard Entry look like a dictation. Holds without speech give no text, see
///   DictationQualityTests.
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
        /// No talk key is down.
        case up
        /// The key is held on its own. A push to talk hold is in progress.
        case holding(TalkKey)
        /// The key is still down but the hold was cancelled. For fn, its release is
        /// swallowed because its press was. If another modifier caused the cancel, apps
        /// that track flags changed events may think fn is still down until the next
        /// modifier change. That is cosmetic.
        case cancelled(TalkKey)
        /// The key went down as part of another shortcut. Its release passes through.
        case passingThrough(TalkKey)

        /// The talk key this phase is about, if any.
        var key: TalkKey? {
            switch self {
            case .up: nil
            case .holding(let key), .cancelled(let key), .passingThrough(let key): key
            }
        }
    }

    static let globeKeyCode: Int64 = 179

    private(set) var keys: Set<TalkKey>
    private(set) var phase: Phase = .up

    init(keys: Set<TalkKey>) {
        self.keys = keys
    }

    /// Replaces the talk keys. Returns `.cancelled` when a hold of a key that is no longer
    /// a talk key was in progress.
    mutating func setKeys(_ newKeys: Set<TalkKey>) -> PushToTalkStateMachine.Event? {
        keys = newKeys
        guard let active = phase.key, !newKeys.contains(active) else { return nil }
        return reset()
    }

    /// Decides what to do with one key down or flags changed event.
    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Decision {
        switch type {
        case .flagsChanged:
            // Only the key this phase is about, or any talk key while no key is down,
            // counts as a talk key event. Everything else is another modifier.
            let key: TalkKey?
            if let active = phase.key {
                key = active.keyCode == keyCode ? active : nil
            } else {
                key = keys.first { $0.keyCode == keyCode }
            }
            guard let key else { return cancelHold() }
            let isDown = key.isDown(in: flags, wasDown: phase.key == key)
            return handleChange(of: key, isDown: isDown, flags: flags)
        case .keyDown where keyCode != Self.globeKeyCode:
            return cancelHold()
        default:
            return .passThrough
        }
    }

    /// A mouse button went down. Ends a hold of a key that modifies clicks, see
    /// `TalkKey.modifiesClicks`, and returns `.cancelled` then.
    mutating func cancelForClick() -> PushToTalkStateMachine.Event? {
        guard case .holding(let key) = phase, key.modifiesClicks else { return nil }
        phase = .cancelled(key)
        return .cancelled
    }

    /// Forgets the current hold, for when the tap was off and may have missed events, or
    /// the key stopped being a talk key. Returns `.cancelled` when a hold was in progress.
    mutating func reset() -> PushToTalkStateMachine.Event? {
        defer { phase = .up }
        if case .holding = phase {
            return .cancelled
        }
        return nil
    }

    private mutating func handleChange(of key: TalkKey, isDown: Bool, flags: CGEventFlags) -> Decision {
        let swallow = key.swallowsItsEvents
        switch (phase, isDown) {
        case (.up, true):
            guard flags.isDisjoint(with: key.otherModifiers) else {
                phase = .passingThrough(key)
                return .passThrough
            }
            phase = .holding(key)
            return Decision(event: .pressed(isRepeat: false), swallow: swallow)
        case (.holding, false):
            phase = .up
            if key.twinIsDown(atReleaseWith: flags) {
                return Decision(event: .cancelled, swallow: swallow)
            }
            return Decision(event: .released, swallow: swallow)
        case (.cancelled, false):
            phase = .up
            return Decision(event: nil, swallow: swallow)
        case (.passingThrough, false):
            phase = .up
            return .passThrough
        case (.up, false), (.passingThrough, true):
            // A release without a press, for example a key held since before launch, or a
            // repeated press that belongs to another shortcut.
            return .passThrough
        case (.holding, true), (.cancelled, true):
            // A repeated press while the key is already down. Keep fn's events hidden.
            return Decision(event: nil, swallow: swallow)
        }
    }

    private mutating func cancelHold() -> Decision {
        guard case .holding(let key) = phase else { return .passThrough }
        phase = .cancelled(key)
        return Decision(event: .cancelled, swallow: false)
    }
}
