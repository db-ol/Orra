import Foundation

/// How long each step of one dictation took, from the release of the talk key to the
/// paste. Durations only, never text, so they can go to the log and to the latency
/// measurement, see LatencyMeasurementTests. PushToTalkController fills one per dictation
/// with a clock reading after each step, which costs well under a microsecond.
nonisolated struct DictationTimings: Equatable, Sendable {
    /// The steps in the order they run. Each one is the time since the step before.
    nonisolated enum Step: String, CaseIterable, Sendable {
        /// From the release until the processing task runs, including the wait for the
        /// microphone's start, which is over long before for any hold but a tap.
        case start
        /// The fixed recording after the release, RecordingLimits.releaseTail.
        case releaseTail
        /// Stopping the microphone and taking its samples.
        case microphoneStop
        /// Resampling to 16 kHz and the silence check.
        case resampling
        /// The speech model, with the language guard, the vocabulary echo check and any
        /// pass either of them asks for.
        case recognition
        /// TranscriptGuard and the conversion to simplified Chinese.
        case transcriptGuard
        case fillers
        case numbers
        case wordReplacement
        /// The translation step, almost nothing for a dictation of the talk key.
        case translation
        /// The wait for a cleanup model that is still loading, almost nothing once loaded.
        case cleanupWait
        /// The cleanup step: the model, reading its answer and the guards.
        case cleanup
        /// The check of the app in front and the paste: the pasteboard, Command V and
        /// what the inserter waits for before it.
        case paste
    }

    let released: ContinuousClock.Instant
    private(set) var durations: [Step: Duration] = [:]
    private var lastLap: ContinuousClock.Instant

    init(releasedAt released: ContinuousClock.Instant) {
        self.released = released
        lastLap = released
    }

    /// Ends a step now: it took the time since the end of the step before.
    mutating func lap(_ step: Step, at now: ContinuousClock.Instant = .now) {
        durations[step, default: .zero] += lastLap.duration(to: now)
        lastLap = now
    }

    /// From the release to the end of the latest step.
    var total: Duration {
        released.duration(to: lastLap)
    }

    /// The steps in milliseconds, for the log. Numbers only.
    var summary: String {
        Step.allCases.compactMap { step in
            durations[step].map { "\(step.rawValue) \(Self.milliseconds($0)) ms" }
        }.joined(separator: ", ")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
