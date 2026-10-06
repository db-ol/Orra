/// The push to talk cycle. Orra listens while the hotkey is held and processes
/// the recording after the key is released.
///
///     idle --press--> listening --release--> processing --finished--> idle
///                     listening --cancel---> idle
///
/// This type is pure logic. It decides what a hotkey event means in the current
/// state and reports the resulting transition, if any. It knows nothing about
/// key codes, audio, or transcription. The owner does the work for each
/// transition and reports back with `processingFinished`.
///
/// Edge case decisions:
/// - Key repeat is ignored in every state. The hotkey layer passes the repeat
///   flag through and this type drops those events.
/// - A press while already listening is ignored. This covers a lost release as
///   well as a repeat the hotkey layer failed to flag.
/// - A release without a press, in idle or in processing, is ignored. This
///   happens when the key was already down at launch, or when the press that
///   started the hold was itself ignored.
/// - A press during processing is ignored. It is not queued, because that could
///   start a recording the user no longer expects, and it does not cancel,
///   because that would throw away a recording the user just finished. The user
///   presses again once Orra is idle.
/// - A cancel while listening ends the hold without processing. The hotkey layer
///   sends it when the hold turns out to be part of a shortcut, such as Fn+Delete,
///   or when it may have missed the release. A cancel in idle or in processing is
///   ignored, so a recording that is already being processed is never thrown away.
/// - `processingFinished` outside of processing is ignored as stale.
nonisolated struct PushToTalkStateMachine: Equatable, Sendable {
    nonisolated enum State: CaseIterable, Equatable, Sendable {
        case idle
        case listening
        case processing
    }

    nonisolated enum Event: Equatable, Sendable {
        /// The hotkey went down. `isRepeat` is true for key repeat events.
        case pressed(isRepeat: Bool)
        /// The hotkey came up.
        case released
        /// The hold should end without processing.
        case cancelled
        /// The work that followed a release is done, with or without a result.
        case processingFinished
    }

    /// What the owner has to do after an event changed the state.
    nonisolated enum Transition: Equatable, Sendable {
        /// idle to listening. Start capturing audio.
        case startedListening
        /// listening to processing. Stop capturing and process the recording.
        case startedProcessing
        /// listening to idle. Stop capturing and discard the recording.
        case cancelledListening
        /// processing to idle. Ready for the next press.
        case finished
    }

    private(set) var state: State = .idle

    init() {}

    /// Applies `event` and returns the transition it caused, or nil when the
    /// event was ignored in the current state.
    mutating func handle(_ event: Event) -> Transition? {
        switch (state, event) {
        case (_, .pressed(isRepeat: true)):
            return nil
        case (.idle, .pressed):
            state = .listening
            return .startedListening
        case (.listening, .released):
            state = .processing
            return .startedProcessing
        case (.listening, .cancelled):
            state = .idle
            return .cancelledListening
        case (.processing, .processingFinished):
            state = .idle
            return .finished
        case (.idle, .released), (.idle, .cancelled), (.idle, .processingFinished),
             (.listening, .pressed), (.listening, .processingFinished),
             (.processing, .pressed), (.processing, .released), (.processing, .cancelled):
            return nil
        }
    }
}
