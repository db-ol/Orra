import Foundation
import NaturalLanguage
import os

/// How the translation key translates one text, see TranslationDirection.plan(for:in:).
///
/// Between English and the dictation language a text takes one route, as always. Into a
/// target outside that pair, such as Japanese for a user who dictates in Chinese, it goes
/// through English: on the route of the dictation language into English, then on the
/// route from English into the target, the one a user who dictates in the target's
/// language takes for English text. Each keeps its prompt, prefix cache and checks, and
/// the second gets the checks of a target outside the pair, see
/// TranslationGuard.checkOutsidePair. English text takes the second route alone, and text
/// already in the target is pasted as it was said.
///
/// This is Beta. A study of 2026-10-20 compared it with direct prompts without examples on
/// 319 FLEURS sentences and the hand written dictations of Tools/rewrite-eval for each of
/// the six directions, see docs/manual-testing.md. Direct prompts kept or turned around
/// spoken self corrections that the route through English applied: of 25 Chinese
/// corrections, through English applied 23 and direct 10 into Japanese and 16 into
/// Spanish. The route through English waits about twice as long, 0.64 to 0.77 s for a
/// dictation at the median on an M5 Pro, against about 0.3 s on one route.
nonisolated enum TranslationPlan: Equatable, Sendable {
    /// On one route. `source` is the language of the text by the rule of the route's
    /// language.
    case route(TranslationRoute, source: TranslationDirection.Source)
    /// Into English on the first route, the text being `source` by the rule of the
    /// dictation language, then from English on `then`.
    case throughEnglish(TranslationRoute, source: TranslationDirection.Source, then: TranslationRoute)
    /// Text in a target outside the pair already, pasted as it was said.
    case inTarget(TranslationTarget)

    /// The language the text is pasted in when the translation passes.
    var target: TranslationTarget {
        switch self {
        case .route(let route, _): route.target
        case .throughEnglish(_, _, let then): then.target
        case .inTarget(let target): target
        }
    }

    /// The plan into `target`, a language outside the pair of `language`, for a text that
    /// is `source` by the rule of `language`, see TranslationDirection.source(of:in:).
    /// English with no word of the dictation language takes the route from English alone.
    /// The language of the text on it is read by that route's rule, so Spanish that the
    /// Chinese or Japanese rule reads as English is pasted as it was said when the target
    /// is Spanish, see TranslationStep.isInItsLanguage. Any other text goes through English,
    /// unless it is in the target already, see `isIn(_:_:)`. So does English mixed with
    /// the dictation language, as in Deadline 是 Friday，sorry，是 Thursday。, whose
    /// correction the route from English into Japanese kept in a run on 2026-10-21, while
    /// the route of Chinese into English applied it.
    static func into(_ target: TranslationTarget, text: String, source: TranslationDirection.Source, in language: DictationLanguage) -> TranslationPlan {
        let last = TranslationRoute.fromEnglish(into: target)
        if source == .english, !holdsWords(of: language, in: text) {
            return .route(last, source: TranslationDirection.source(of: text, in: last.language) ?? .english)
        }
        if isIn(target, text) {
            return .inTarget(target)
        }
        return .throughEnglish(TranslationRoute(language, into: .english), source: source, then: last)
    }

    /// Whether a text holds words of `language`: a Han character for Chinese, and for
    /// Japanese and Spanish what TranslationDirection.holdsWords(of:in:) counts.
    static func holdsWords(of language: DictationLanguage, in text: String) -> Bool {
        language == .chinese ? text.unicodeScalars.contains(where: TranslationDirection.isHan) : TranslationDirection.holdsWords(of: language, in: text)
    }

    /// Whether a text is in `target` already:
    /// - Japanese: it holds kana, and the Japanese rule reads it as Japanese. Japanese with
    ///   kanji reads as Chinese under the Chinese rule.
    /// - Chinese: it holds no kana, the Chinese rule reads it as Chinese, as Chinese reads as
    ///   Japanese under the Japanese rule and as neither under the Spanish one, and
    ///   NLLanguageRecognizer, held to Chinese and Japanese, does not find it Japanese. A
    ///   sentence with a short Chinese name, such as Saluda a 王小明., is not Chinese. Japanese
    ///   in kanji only, such as 品川駅集合。, is Japanese for the recognizer, which read 3 of
    ///   the 5 such cases of Tools/rewrite-eval right, and 1 of 2,052 Chinese texts of the
    ///   measurements of 2026-10-19 (三十所学校。) as Japanese, which then goes through
    ///   English. The other two, 契約書最終確認後、署名予定。 and 2026年, are pasted as said.
    ///   Rare in speech.
    /// - Spanish: the Spanish rule reads it as Spanish, which text that the Chinese or
    ///   Japanese rule reads as Chinese, Japanese or neither never is.
    static func isIn(_ target: TranslationTarget, _ text: String) -> Bool {
        let kana = text.precomposedStringWithCompatibilityMapping.unicodeScalars.contains { $0.properties.isAlphabetic && LanguageGuard.isKana($0) }
        switch target {
        case .japanese: return kana && TranslationDirection.japaneseSource(of: text) == .partner
        case .chinese: return !kana && TranslationDirection.sourceLanguage(of: text) == .chinese && !readsAsJapanese(text)
        case .spanish: return TranslationDirection.spanishSource(of: text) == .partner
        case .english: return false
        }
    }

    /// Whether NLLanguageRecognizer, held to simplified and traditional Chinese and
    /// Japanese, finds a text Japanese.
    static func readsAsJapanese(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese]
        recognizer.processString(text)
        return recognizer.dominantLanguage == .japanese
    }
}

nonisolated extension DictationLanguage {
    /// The dictation language whose pair holds `target` besides English, nil for English.
    init?(pairOf target: TranslationTarget) {
        switch target {
        case .english: return nil
        case .chinese: self = .chinese
        case .japanese: self = .japanese
        case .spanish: self = .spanish
        }
    }
}

nonisolated extension TranslationRoute {
    /// The route from English into `target`, Chinese, Japanese or Spanish: the one a user
    /// who dictates in that language takes for English text.
    static func fromEnglish(into target: TranslationTarget) -> TranslationRoute {
        guard let language = DictationLanguage(pairOf: target) else {
            preconditionFailure("No route from English into English")
        }
        return TranslationRoute(language, into: target)
    }
}

nonisolated extension TranslationStep {
    /// The text to paste and what happened, by `plan`: on one route as
    /// `run(_:into:source:cleansUp:timeout:outsidePair:complete:)` does, with the checks of
    /// a target outside the pair when the route is one, through English, or the text as it
    /// was said when it is in the target already.
    @concurrent
    static func run(
        _ text: String,
        plan: TranslationPlan,
        in language: DictationLanguage,
        cleansUp: Bool,
        timeout: Duration? = nil,
        complete: @escaping @Sendable (String, TranslationRoute) async throws -> String
    ) async -> Result {
        switch plan {
        case .route(let route, let source):
            let outsidePair = !language.translationTargets.contains(route.target)
            return await run(text, into: route, source: source, cleansUp: cleansUp, timeout: timeout, outsidePair: outsidePair, complete: complete)
        case .throughEnglish(let first, let source, let then):
            return await run(text, into: first, source: source, then: then, cleansUp: cleansUp, timeout: timeout, complete: complete)
        case .inTarget(let target):
            Logger.rewrite.notice("Translation into \(target.logName, privacy: .public) not needed, the text is in that language")
            return Result(text: text, untranslated: text, outcome: .unchanged)
        }
    }

    /// The text to paste and what happened, through English: the text into English on
    /// `first`, as on one route, then the English on `then`, with the checks of a target
    /// outside the pair. Both share one time limit, `timeout(for:)` of the text, which no
    /// hand written dictation passed in the study through English. A translation is pasted
    /// only when both pass, and otherwise the text without translation, which the first
    /// may take from the model's cleanup as on one route. English that the second gives
    /// back as it was, such as OK, passed its checks and is the translation.
    @concurrent
    static func run(
        _ text: String,
        into first: TranslationRoute,
        source: TranslationDirection.Source,
        then: TranslationRoute,
        cleansUp: Bool,
        timeout: Duration? = nil,
        complete: @escaping @Sendable (String, TranslationRoute) async throws -> String
    ) async -> Result {
        let limit = timeout ?? Self.timeout(for: text)
        let started = ContinuousClock.now
        let english = await run(text, into: first, source: source, cleansUp: cleansUp, timeout: limit, complete: complete)
        let result = await translateEnglish(english, into: then, within: limit - started.duration(to: .now), complete: complete)
        Logger.rewrite.notice("Translation into \(then.target.logName, privacy: .public) through English \(result.outcome.logName, privacy: .public) after \(started.duration(to: .now), privacy: .public)")
        return result
    }

    /// The second part of a translation through English: `english`, the result into
    /// English, translated on `route` within `left`. A first part that failed stops here.
    private static func translateEnglish(
        _ english: Result,
        into route: TranslationRoute,
        within left: Duration,
        complete: @escaping @Sendable (String, TranslationRoute) async throws -> String
    ) async -> Result {
        let untranslated = english.untranslated
        switch english.outcome {
        case .translated, .unchanged:
            break
        case .unreadable, .heldBack, .timedOut, .failed:
            return english
        }
        guard left > .zero else {
            return Result(text: untranslated, untranslated: untranslated, outcome: .timedOut)
        }
        // The text is English, whatever the rule of the target's language reads, so the
        // model always runs.
        let last = await run(english.text, into: route, source: .english, cleansUp: false, timeout: left, outsidePair: true, complete: complete)
        switch last.outcome {
        case .translated, .unchanged:
            return Result(text: last.text, untranslated: untranslated, outcome: last.text == untranslated ? .unchanged : .translated)
        case .unreadable, .heldBack, .timedOut, .failed:
            return Result(text: untranslated, untranslated: untranslated, outcome: last.outcome)
        }
    }
}
