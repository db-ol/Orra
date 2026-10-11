/// The push to talk cycle. Orra listens while the hotkey is held and processes
/// the recording after the key is released. A quick double press starts a hands free
/// dictation instead, which listens until the next press of the key.
///
///     idle --press--> listening --release--> processing --finished--> idle
///                     listening --cancel---> idle
///                     listening --tap------> waitingForSecondPress
///     waitingForSecondPress --press---------> listening
///     listening --double press--> handsFree
///     waitingForSecondPress --double press--> handsFree
///     waitingForSecondPress --cancel--------> idle
///     idle --double press--> handsFree --release--> processing
///                            handsFree --cancel---> idle
///
/// This type is pure logic. It decides what a hotkey event means in the current
/// state and reports the resulting transition, if any. It knows nothing about
/// key codes, timing, audio, or transcription. TalkKeyDetector tells a tap from a
/// hold and a double press from two presses. The owner does the work for each
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
///   presses again once Orra is idle. A double press during processing is ignored
///   the same way.
/// - A cancel while listening ends the hold without processing. The hotkey layer
///   sends it when the hold turns out to be part of a shortcut, such as Fn+Delete,
///   or when it may have missed the release. A cancel in idle or in processing is
///   ignored, so a recording that is already being processed is never thrown away.
/// - A tap while listening keeps the recording going while the hotkey layer waits
///   for a second press. The second press goes back to listening, still on the same
///   recording, because only its release tells a double press from a tap followed by a
///   hold. A double press, sent at that release, then turns the recording into a hands
///   free dictation, so the first words are not lost to a restart of the microphone. A
///   release after a longer second press processes it like any hold. When no second
///   press comes, the hotkey layer sends a cancel and the tap's recording, which was too
///   short to transcribe, is discarded.
/// - A double press in idle starts a hands free dictation with a new recording. That
///   happens for a left hand key, whose tap never started a recording.
/// - During a hands free dictation, a release ends it and processes the recording,
///   and a cancel, from Escape or a change of keys, discards it. A press, tap or
///   double press then is ignored. The hotkey layer sends a release only for a press
///   on its own, not for the release of the double press that started it.
/// - `processingFinished` outside of processing is ignored as stale.
nonisolated struct PushToTalkStateMachine: Equatable, Sendable {
    nonisolated enum State: CaseIterable, Equatable, Sendable {
        case idle
        case listening
        /// The key was tapped. The recording goes on until the second press or the end
        /// of the window for it.
        case waitingForSecondPress
        /// A hands free dictation listens until the key is pressed again.
        case handsFree
        case processing
    }

    nonisolated enum Event: Equatable, Sendable {
        /// The hotkey went down. `isRepeat` is true for key repeat events.
        case pressed(isRepeat: Bool)
        /// The hotkey came up after a hold, or after the press that ends a hands free
        /// dictation.
        case released
        /// The hotkey came up so soon that the press may be the first half of a double
        /// press.
        case tapped
        /// The hotkey went down again soon after a tap.
        case doublePressed
        /// The hold or the hands free dictation should end without processing.
        case cancelled
        /// The work that followed a release is done, with or without a result.
        case processingFinished
    }

    /// What the owner has to do after an event changed the state.
    nonisolated enum Transition: Equatable, Sendable {
        /// idle to listening. Start capturing audio.
        case startedListening
        /// listening to waitingForSecondPress. Keep capturing.
        case awaitingSecondPress
        /// waitingForSecondPress to listening. Keep capturing, the second press may be a
        /// hold.
        case resumedListening
        /// idle to handsFree. Start capturing audio.
        case startedHandsFree
        /// listening or waitingForSecondPress to handsFree. Keep capturing, the dictation
        /// goes on after the key comes up.
        case switchedToHandsFree
        /// listening or handsFree to processing. Stop capturing and process the recording.
        case startedProcessing
        /// listening, waitingForSecondPress or handsFree to idle. Stop capturing and
        /// discard the recording.
        case cancelledListening
        /// processing to idle. Ready for the next press.
        case finished
    }

    private(set) var state: State = .idle

    init() {}

    /// Whether the microphone records in this state.
    var isRecording: Bool {
        switch state {
        case .listening, .waitingForSecondPress, .handsFree: true
        case .idle, .processing: false
        }
    }

    /// Applies `event` and returns the transition it caused, or nil when the
    /// event was ignored in the current state.
    mutating func handle(_ event: Event) -> Transition? {
        switch (state, event) {
        case (_, .pressed(isRepeat: true)):
            return nil
        case (.idle, .pressed):
            state = .listening
            return .startedListening
        case (.idle, .doublePressed):
            state = .handsFree
            return .startedHandsFree
        case (.listening, .released), (.handsFree, .released):
            state = .processing
            return .startedProcessing
        case (.listening, .tapped):
            state = .waitingForSecondPress
            return .awaitingSecondPress
        case (.waitingForSecondPress, .pressed):
            state = .listening
            return .resumedListening
        case (.listening, .doublePressed), (.waitingForSecondPress, .doublePressed):
            state = .handsFree
            return .switchedToHandsFree
        case (.listening, .cancelled), (.waitingForSecondPress, .cancelled), (.handsFree, .cancelled):
            state = .idle
            return .cancelledListening
        case (.processing, .processingFinished):
            state = .idle
            return .finished
        case (.idle, .released), (.idle, .tapped), (.idle, .cancelled), (.idle, .processingFinished),
             (.listening, .pressed), (.listening, .processingFinished),
             (.waitingForSecondPress, .released),
             (.waitingForSecondPress, .tapped), (.waitingForSecondPress, .processingFinished),
             (.handsFree, .pressed), (.handsFree, .tapped), (.handsFree, .doublePressed),
             (.handsFree, .processingFinished),
             (.processing, .pressed), (.processing, .released), (.processing, .tapped),
             (.processing, .doublePressed), (.processing, .cancelled):
            return nil
        }
    }
}
