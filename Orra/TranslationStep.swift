import Foundation
import os

/// The translation step after the rule steps, in place of the cleanup step: runs the model
/// on the translation prompt, reads its answer and checks it. A translation that fails a
/// check, a timeout, an error or an answer that cannot be read leaves the text without
/// translation, so a dictation is never lost: the model's cleanup of it when cleanup is on
/// and the cleanup passes RewriteGuard, and the text the step got otherwise.
nonisolated enum TranslationStep {
    nonisolated enum Outcome: Equatable, Sendable {
        /// The translation passed the checks and differs from the text.
        case translated
        /// The model gave the text back as it was.
        case unchanged
        /// The answer was not the JSON object the prompt asks for.
        case unreadable
        case heldBack(TranslationGuard.Failure)
        case timedOut
        case failed

        /// For the log, without any text.
        var logName: String {
            switch self {
            case .translated: "translated"
            case .unchanged: "unchanged"
            case .unreadable: "answer not readable"
            case .heldBack(let failure): "held back by the \(failure.logName) check"
            case .timedOut: "timed out"
            case .failed: "failed"
            }
        }
    }

    /// What the step gives back.
    struct Result: Equatable, Sendable {
        /// The text to paste: the translation, or the untranslated text.
        let text: String
        /// The dictation without translation, which Paste Original Text pastes: the model's
        /// cleanup when cleanup is on and it passed the cleanup checks, and the text the
        /// step got otherwise. The same as `text` unless the outcome is `translated`.
        let untranslated: String
        let outcome: Outcome

        /// Whether `text` is a translation. Orra never learns corrections from one.
        var isTranslation: Bool {
            outcome == .translated
        }
    }

    /// The longest Orra waits for a translation of this text before it pastes the text
    /// without it. The model writes the text twice, once cleaned up and once translated,
    /// so the time grows with its length. In the benchmark on an M5 Pro, with the prefix
    /// cache, the median took 0.31 s and the slowest 4.6 s, for 308 characters, and this
    /// left every run at least 2.4 s to spare.
    static func timeout(for text: String) -> Duration {
        .seconds(3) + .milliseconds(30) * text.count
    }

    /// The longest text Orra translates, in characters. A longer one would keep the user
    /// waiting several seconds for the paste, so it is pasted without translation.
    static let maximumLength = 300

    /// Whether a text can be translated: something to translate, a Han character or a Latin
    /// letter, however short, and no longer than `maximumLength`.
    static func isWorthTranslating(_ text: String) -> Bool {
        text.count <= maximumLength && TranslationDirection.sourceLanguage(of: text) != nil
    }

    /// The text to paste and what happened. `cleansUp` says whether cleanup is on, so the
    /// model's cleanup may stand in for the translation. Logs the outcome and the time,
    /// never text.
    @concurrent
    static func run(
        _ text: String,
        into target: TranslationTarget,
        cleansUp: Bool,
        timeout: Duration? = nil,
        complete: @escaping @Sendable (String, TranslationTarget) async throws -> String
    ) async -> Result {
        let started = ContinuousClock.now
        let work = Task { try await complete(text, target) }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout ?? Self.timeout(for: text))
            } catch {
                return false
            }
            work.cancel()
            return true
        }
        let result = await work.result
        timer.cancel()
        let timedOut = await timer.value
        var outcome = Outcome.failed
        var untranslated = text
        var translation: String?
        var cleanup = "not used"
        if timedOut {
            outcome = .timedOut
        } else {
            switch result {
            case .success(let answer):
                if let parsed = TranslationPrompt.parse(answer) {
                    if cleansUp, CleanupStep.isWorthCleaning(text) {
                        if parsed.cleaned.isEmpty {
                            cleanup = "held back by the empty check"
                        } else if let failure = RewriteGuard.check(source: text, output: parsed.cleaned) {
                            cleanup = "held back by the \(failure.logName) check"
                        } else {
                            untranslated = parsed.cleaned
                            cleanup = "used"
                        }
                    }
                    if let failure = TranslationGuard.check(source: text, output: parsed.translation, target: target) {
                        outcome = .heldBack(failure)
                    } else if parsed.translation == text {
                        outcome = .unchanged
                    } else {
                        outcome = .translated
                        translation = parsed.translation
                    }
                } else {
                    outcome = .unreadable
                }
            case .failure(let error):
                outcome = .failed
                Logger.rewrite.error("Translation failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        Logger.rewrite.notice("Translation into \(target.logName, privacy: .public) \(outcome.logName, privacy: .public) after \(started.duration(to: .now), privacy: .public), its cleanup \(cleanup, privacy: .public)")
        return Result(text: translation ?? untranslated, untranslated: untranslated, outcome: outcome)
    }
}

/// What PushToTalkController needs from the model for translations. Closures, so tests
/// pass fakes.
struct TranslationModel {
    /// Whether translation is on and the model is loaded, so a translation can start at
    /// once. False while the model is unloaded after a while without a dictation.
    var isReady: () -> Bool
    /// Whether the model can translate now, after waiting a bounded time for a load the
    /// press of the key started, see TextCleanup.waitUntilLoadedForTranslation.
    var waitUntilLoaded: () async -> Bool
    /// Which way to translate, as the user set it.
    var direction: () -> TranslationDirection
    /// The model's answer for a transcript and a target, see RewriteEngine.translate.
    var complete: @Sendable (String, TranslationTarget) async throws -> String

    /// Without `waitUntilLoaded`, nothing is waited for and `isReady` decides.
    init(
        isReady: @escaping () -> Bool,
        waitUntilLoaded: (() async -> Bool)? = nil,
        direction: @escaping () -> TranslationDirection,
        complete: @escaping @Sendable (String, TranslationTarget) async throws -> String
    ) {
        self.isReady = isReady
        self.waitUntilLoaded = waitUntilLoaded ?? { isReady() }
        self.direction = direction
        self.complete = complete
    }

    /// No translation, for tests and previews.
    static let off = TranslationModel(isReady: { false }, direction: { .automatic }, complete: { _, _ in throw RewriteError.notLoaded })
}
