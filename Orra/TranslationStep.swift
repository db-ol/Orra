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

    /// Whether a text of a user who dictates in `language` can be translated: a letter of
    /// any script for Japanese and Spanish, kana only Japanese among them, and the rule
    /// above for Chinese.
    static func isWorthTranslating(_ text: String, in language: DictationLanguage) -> Bool {
        text.count <= maximumLength && TranslationDirection.source(of: text, in: language) != nil
    }

    /// The outcome for the model's answer for `text`, as TranslationPrompt.parse read it:
    /// unreadable when it could not be read, held back when the translation fails a check,
    /// unchanged when it is the text itself, and translated otherwise. Captions use it too.
    static func verdict(on answer: TranslationPrompt.Answer?, for text: String, into target: TranslationTarget) -> Outcome {
        guard let answer else { return .unreadable }
        if let failure = TranslationGuard.check(source: text, output: answer.translation, target: target) {
            return .heldBack(failure)
        }
        return answer.translation == text ? .unchanged : .translated
    }

    /// The outcome on a route, the same way, for text whose language `source` the caller
    /// read, see TranslationDirection.plan(for:in:). The Chinese routes get the verdict
    /// above. On the others, for text in the target language already, a translation that
    /// only repeats the model's cleanup is unchanged too, so the model's cleanup never
    /// pastes as a translation. Text in the other language keeps a translation that the
    /// model also wrote into "cleaned", which it sometimes does, and so does English text
    /// with words of the dictation language, such as "I'll send it 明日の朝。", whose
    /// translation translates them, see TranslationDirection.holdsWords(of:in:). With
    /// `outsidePair` the route takes the user's text into a target outside their pair, see
    /// TranslationPlan, and the translation gets the checks of such a route, see
    /// TranslationGuard.checkOutsidePair(source:output:route:).
    static func verdict(on answer: TranslationPrompt.Answer?, for text: String, into route: TranslationRoute, source: TranslationDirection.Source?, outsidePair: Bool = false) -> Outcome {
        guard route.language != .chinese else { return verdict(on: answer, for: text, into: route.target) }
        guard let answer else { return .unreadable }
        let failure = outsidePair
            ? TranslationGuard.checkOutsidePair(source: text, output: answer.translation, route: route)
            : TranslationGuard.check(source: text, output: answer.translation, route: route)
        if let failure {
            return .heldBack(failure)
        }
        if answer.translation == text {
            return .unchanged
        }
        let inTarget = source == (route.target == .english ? .english : .partner)
        let repeatsCleanup = answer.translation == answer.cleaned && !TranslationDirection.holdsWords(of: route.language, in: text)
        return inTarget && repeatsCleanup ? .unchanged : .translated
    }

    /// The text to paste and what happened, on a Chinese route. `cleansUp` says whether
    /// cleanup is on, so the model's cleanup may stand in for the translation. Logs the
    /// outcome and the time, never text.
    @concurrent
    static func run(
        _ text: String,
        into target: TranslationTarget,
        cleansUp: Bool,
        timeout: Duration? = nil,
        complete: @escaping @Sendable (String, TranslationTarget) async throws -> String
    ) async -> Result {
        await run(text, into: .chinese(target), cleansUp: cleansUp, timeout: timeout) { text, route in
            try await complete(text, route.target)
        }
    }

    /// Whether a route of Japanese or Spanish into that language has its text in that
    /// language already, so the model has nothing to translate. Its rewrite would only
    /// restyle or clean up the text, which Orra never pastes for Japanese or Spanish, so
    /// the model does not run. The Chinese routes always run it.
    static func isInItsLanguage(_ text: String, on route: TranslationRoute) -> Bool {
        route.language != .chinese && isInItsLanguage(source: TranslationDirection.source(of: text, in: route.language), on: route)
    }

    /// The same for text whose language the caller read already, see
    /// TranslationDirection.plan(for:in:).
    static func isInItsLanguage(source: TranslationDirection.Source?, on route: TranslationRoute) -> Bool {
        route.language != .chinese && route.target != .english && source == .partner
    }

    /// The text to paste and what happened, on any route, the same way. On a route of
    /// Japanese or Spanish, text in the target language already is pasted as it is, see
    /// `isInItsLanguage(_:on:)`, and a translation that only repeats the model's cleanup
    /// pastes the text the step got unless cleanup stands in, see
    /// `verdict(on:for:into:source:)`. The model's cleanup never stands in for text with
    /// words of the dictation language, such as "The new office is near 品川.", whose
    /// cleanup may translate them, so Paste Original Text brings back 品川.
    @concurrent
    static func run(
        _ text: String,
        into route: TranslationRoute,
        cleansUp: Bool,
        timeout: Duration? = nil,
        complete: @escaping @Sendable (String, TranslationRoute) async throws -> String
    ) async -> Result {
        await run(text, into: route, source: TranslationDirection.source(of: text, in: route.language), cleansUp: cleansUp, timeout: timeout, complete: complete)
    }

    /// The same for text whose language `source` the caller read already, see
    /// TranslationDirection.plan(for:in:). With `outsidePair` the route takes the text
    /// into a target outside the user's pair, with the checks of such a route, see
    /// `verdict(on:for:into:source:outsidePair:)`.
    @concurrent
    static func run(
        _ text: String,
        into route: TranslationRoute,
        source: TranslationDirection.Source?,
        cleansUp: Bool,
        timeout: Duration? = nil,
        outsidePair: Bool = false,
        complete: @escaping @Sendable (String, TranslationRoute) async throws -> String
    ) async -> Result {
        if isInItsLanguage(source: source, on: route) {
            Logger.rewrite.notice("Translation into \(route.logName, privacy: .public) not needed, the text is in that language")
            return Result(text: text, untranslated: text, outcome: .unchanged)
        }
        let cleansUp = cleansUp && !TranslationDirection.holdsWords(of: route.language, in: text)
        let started = ContinuousClock.now
        let (result, timedOut) = await TimedCall.run(within: timeout ?? Self.timeout(for: text)) { try await complete(text, route) }
        var outcome = Outcome.failed
        var untranslated = text
        var translation: String?
        var cleanup = "not used"
        if timedOut {
            outcome = .timedOut
        } else {
            switch result {
            case .success(let answer):
                let parsed = TranslationPrompt.parse(answer, for: text, on: route)
                if let parsed, cleansUp, CleanupStep.isWorthCleaning(text) {
                    if let failure = CleanupStep.check(parsed.cleaned, of: text) {
                        cleanup = "held back by the \(failure.logName) check"
                    } else {
                        untranslated = parsed.cleaned
                        cleanup = "used"
                    }
                }
                outcome = verdict(on: parsed, for: text, into: route, source: source, outsidePair: outsidePair)
                if outcome == .translated {
                    translation = parsed?.translation
                }
            case .failure(let error):
                outcome = .failed
                Logger.rewrite.error("Translation failed with \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        Logger.rewrite.notice("Translation into \(route.logName, privacy: .public) \(outcome.logName, privacy: .public) after \(started.duration(to: .now), privacy: .public), its cleanup \(cleanup, privacy: .public)")
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
    /// Which way to translate, as the user set it. Each dictation plans its routes for the
    /// dictation language, see TranslationDirection.plan(for:in:).
    var direction: () -> TranslationDirection
    /// The model's answer for a transcript and a route, see RewriteEngine.translate.
    var complete: @Sendable (String, TranslationRoute) async throws -> String

    /// Without `waitUntilLoaded`, nothing is waited for and `isReady` decides.
    init(
        isReady: @escaping () -> Bool,
        waitUntilLoaded: (() async -> Bool)? = nil,
        direction: @escaping () -> TranslationDirection,
        complete: @escaping @Sendable (String, TranslationRoute) async throws -> String
    ) {
        self.isReady = isReady
        self.waitUntilLoaded = waitUntilLoaded ?? { isReady() }
        self.direction = direction
        self.complete = complete
    }

    /// No translation, for tests and previews.
    static let off = TranslationModel(isReady: { false }, direction: { .automatic }, complete: { _, _ in throw RewriteError.notLoaded })
}
