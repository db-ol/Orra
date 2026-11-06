import Foundation
import os

/// How meeting captions share the speech model and the cleanup model with dictation.
///
/// Both models are actors that run one call at a time, and a call cannot be interrupted
/// halfway except a cleanup model call, which stops early when its task is cancelled. So
/// dictation keeps priority this way:
///
/// - Dictation never waits here. Its calls go straight to the models, as before captions.
/// - From the press of the talk key or the translation key until the dictation is pasted
///   or cancelled, captions start no model call. Sentences of what the Mac plays heard
///   meanwhile wait in order and are captioned after the dictation. Captions of the
///   microphone drop what it hears meanwhile before it reaches them, see
///   MeetingCaptions.MicrophonePause, so no caption call is ever made from what the user
///   dictates.
/// - A caption call already running when the key goes down is cancelled. A translation
///   then stops within a token or so and runs again after the dictation. A transcription
///   cannot stop early, but a caption sentence is at most about 12 s of audio, which the
///   speech model transcribes in well under a second, and the dictation is still being
///   recorded meanwhile. So a dictation waits at most for the end of one short caption
///   call, and usually not at all.
///
/// Transcribe File takes its turns the same way, one call for each segment of the file,
/// see FileTranscription. It waits while captions run, so the two rarely run at once,
/// and a press cancels every call under way.
///
/// Main actor state, since the controller reports dictations on the main actor.
@Observable
final class EngineTurns {
    /// True from the press of a key until the dictation is over.
    private(set) var isDictating = false
    /// True once the dictation has gone on for `noteDelay`, until it is over, so the
    /// caption window says that captions wait. A tap of the talk key, or a shortcut with
    /// it such as right Control+C, is a dictation for a moment too, and a note at each
    /// would flash.
    private(set) var dictationNoteDue = false
    /// The calls running now, by their number, each cancelled when a dictation starts.
    @ObservationIgnored private var running: [Int: any CancellableTask] = [:]
    /// Counts the calls, for their numbers in `running`.
    @ObservationIgnored private var calls = 0
    /// Counts dictations, so a call can tell it was cancelled for one.
    @ObservationIgnored private var dictations = 0
    /// How often a waiting caption call looks again whether the dictation is over.
    @ObservationIgnored private let pollInterval: Duration
    /// How long a dictation goes on before `dictationNoteDue`. The app's 1 s is longer
    /// than a tap of the talk key and the wait for a second press after it, 0.7 s in all,
    /// see TalkKeyDetector.
    @ObservationIgnored private let noteDelay: Duration
    /// Sets `dictationNoteDue` once the dictation has gone on for `noteDelay`.
    @ObservationIgnored private var noteTimer: Task<Void, Never>?
    /// What runs at each press of a key, see `whenDictationStarts(_:)`.
    @ObservationIgnored private var startHandlers: [() -> Void] = []

    init(pollInterval: Duration = .milliseconds(100), noteDelay: Duration = .seconds(1)) {
        self.pollInterval = pollInterval
        self.noteDelay = noteDelay
    }

    /// The talk key or the translation key went down.
    func dictationStarted() {
        isDictating = true
        dictations += 1
        for call in running.values {
            call.cancel()
        }
        let dictation = dictations
        noteTimer?.cancel()
        noteTimer = Task { [weak self, noteDelay] in
            try? await Task.sleep(for: noteDelay)
            guard let self, dictations == dictation, isDictating else { return }
            dictationNoteDue = true
        }
        for handler in startHandlers {
            handler()
        }
    }

    /// Runs `handler` at each press of a key from now on, after `isDictating` turned true
    /// and before the dictation reserves the model gate, so other model work can leave the
    /// gate as captions do. Projects ends its call under way this way, see
    /// ProjectsModelQueue.dictationStarted.
    func whenDictationStarts(_ handler: @escaping () -> Void) {
        startHandlers.append(handler)
    }

    /// The dictation was pasted or cancelled.
    func dictationEnded() {
        isDictating = false
        dictationNoteDue = false
        noteTimer?.cancel()
        noteTimer = nil
    }

    /// Who makes a call through `turn(for:retries:_:)`, for the log.
    nonisolated enum Caller: String, Sendable {
        case caption
        case file
    }

    /// Runs a caption call on a model once no dictation is under way. When a dictation
    /// cancels it, it runs again after that dictation, at most `retries` times. Throws
    /// CancellationError when the caller is cancelled, such as when captions are turned
    /// off.
    func captionTurn<T: Sendable>(retries: Int = 3, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await turn(for: .caption, retries: retries, work)
    }

    /// Runs a call on a model once no dictation is under way, the way `captionTurn` does
    /// for captions, for `caller`. Several calls may run at once, such as a caption and a
    /// segment of Transcribe File, and a press cancels all of them.
    func turn<T: Sendable>(for caller: Caller, retries: Int = 3, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            while isDictating {
                try await Task.sleep(for: pollInterval)
            }
            try Task.checkCancellation()
            let dictation = dictations
            calls += 1
            let call = calls
            let task = Task { try await work() }
            running[call] = task
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
            running[call] = nil
            try Task.checkCancellation()
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                // Cancelled for a dictation: once more after it.
                if dictation != dictations, attempt < retries {
                    attempt += 1
                    Logger.captions.notice("A \(caller.rawValue, privacy: .public) call gave way to a dictation, running it again after it")
                    continue
                }
                throw error
            }
        }
    }
}

extension EngineTurns {
    /// A caption call on the cleanup model, through `captionTurn`. When its task is
    /// cancelled while the model runs, the model stops early but returns what it wrote so
    /// far instead of throwing, see RewriteEngine.generate. Such a cut off answer is never
    /// used here. It counts as cancelled, so the call runs again after the dictation. A
    /// call cancelled before the model started throws CancellationError, and runs again
    /// the same way.
    func captionTranslationTurn<T: Sendable>(retries: Int = 3, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await captionTurn(retries: retries) {
            let value = try await work()
            try Task.checkCancellation()
            return value
        }
    }
}

extension CleanupModel {
    /// The same model, telling `turns` when a dictation starts and ends, so captions give
    /// way to it. AppDelegate passes this to PushToTalkController.
    func sharing(_ turns: EngineTurns) -> CleanupModel {
        var model = self
        let started = dictationStarted
        let ended = dictationEnded
        model.dictationStarted = {
            turns.dictationStarted()
            started()
        }
        model.dictationEnded = {
            turns.dictationEnded()
            ended()
        }
        return model
    }
}

/// A task of any result type, for `running`.
private protocol CancellableTask {
    func cancel()
}

extension Task: CancellableTask {}

extension Logger {
    /// Meeting captions. Counts, timings and states only, never text or audio.
    nonisolated static let captions = Logger(subsystem: ProblemReport.subsystem, category: "captions")
}
