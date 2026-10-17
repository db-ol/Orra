import Foundation

/// How the microphone started for one hold, measured from the moment the talk key went
/// down, so the log shows how much of the start of speech a hold may miss. Numbers only,
/// never text or audio. PushToTalkController logs one line per hold whose microphone
/// started, once its dictation is pasted or ends otherwise, or when it is cancelled.
nonisolated struct CaptureTimings: Equatable, Sendable {
    /// When the event tap saw the key go down, or the press start when no tap reported it.
    let keyDown: ContinuousClock.Instant
    /// Whether the press waited before it counted, as a left hand key and the translation
    /// key do.
    let waited: Bool
    /// When the press counted, for the wait. Nil while it has not.
    var counted: ContinuousClock.Instant?
    /// When the microphone's start returned.
    var startReturned: ContinuousClock.Instant?
    var onset = CaptureOnset()

    init(keyDown: ContinuousClock.Instant, waited: Bool) {
        self.keyDown = keyDown
        self.waited = waited
    }

    /// The line for the log, such as "key waited yes 301 ms, path unit, transport usb, from
    /// key down: start returned 335 ms, first buffer 348 ms, first sound 352 ms". A time
    /// that never came reads "none".
    var summary: String {
        let wait = waited ? "yes \(milliseconds(to: counted))" : "no"
        let path = onset.path?.rawValue ?? "none"
        let transport = onset.transport == 0 ? "none" : AudioInput.fourCC(onset.transport).trimmingCharacters(in: .whitespaces)
        return "key waited \(wait), path \(path), transport \(transport), from key down: start returned \(milliseconds(to: startReturned)), first buffer \(milliseconds(to: onset.firstBuffer)), first sound \(milliseconds(to: onset.firstSound))"
    }

    private func milliseconds(to instant: ContinuousClock.Instant?) -> String {
        guard let instant else { return "none" }
        return "\(DictationTimings.milliseconds(keyDown.duration(to: instant))) ms"
    }
}
