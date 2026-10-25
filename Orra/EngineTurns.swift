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
///   or cancelled, captions start no model call. Sentences heard meanwhile wait in order
///   and are captioned after the dictation.
/// - A caption call already running when the key goes down is cancelled. A translation
///   then stops within a token or so and runs again after the dictation. A transcription
///   cannot stop early, but a caption sentence is at most about 12 s of audio, which the
///   speech model transcribes in well under a second, and the dictation is still being
///   recorded meanwhile. So a dictation waits at most for the end of one short caption
///   call, and usually not at all.
///
/// Main actor state, since the controller reports dictations on the main actor.
@Observable
final class EngineTurns {
    /// True from the press of a key until the dictation is over.
    private(set) var isDictating = false
    /// The caption call running now, cancelled when a dictation starts.
    @ObservationIgnored private var running: CancellableTask?
    /// Counts dictations, so a caption call can tell it was cancelled for one.
    @ObservationIgnored private var dictations = 0
    /// How often a waiting caption call looks again whether the dictation is over.
    @ObservationIgnored private let pollInterval: Duration
    /// What runs at each press of a key, see `whenDictationStarts(_:)`.
    @ObservationIgnored private var startHandlers: [() -> Void] = []

    init(pollInterval: Duration = .milliseconds(100)) {
        self.pollInterval = pollInterval
    }

    /// The talk key or the translation key went down.
    func dictationStarted() {
        isDictating = true
        dictations += 1
        running?.cancel()
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
    }

    /// Runs a caption call on a model once no dictation is under way. When a dictation
    /// cancels it, it runs again after that dictation, at most `retries` times. Throws
    /// CancellationError when the caller is cancelled, such as when captions are turned
    /// off.
    func captionTurn<T: Sendable>(retries: Int = 3, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            while isDictating {
                try await Task.sleep(for: pollInterval)
            }
            try Task.checkCancellation()
            let dictation = dictations
            let task = Task { try await work() }
            running = task
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
            running = nil
            try Task.checkCancellation()
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                // Cancelled for a dictation: once more after it.
                if dictation != dictations, attempt < retries {
                    attempt += 1
                    Logger.captions.notice("A caption call gave way to a dictation, running it again after it")
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
