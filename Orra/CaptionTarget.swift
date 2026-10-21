import Foundation
import NaturalLanguage

/// The language Live Captions translate into, apart from Translate into of the translation
/// key. Captions are what the user reads, the translation key is what others read or hear,
/// so each has its own setting. The caption window and the Meeting Interpretation page
/// choose it, and both write the same value, see CaptionTargetPreference.
///
/// Captions offer all four languages Orra knows, whatever the dictation language, see
/// `choices(for:)`. Each sentence is read by its script, see `language(of:)`, and goes into
/// the target by the routes of `hops(from:into:)`: one route between English and another
/// language, and for two languages other than English the route into English and then
/// the route from English, a beta. A sentence in the target already, in a fifth language
/// or with nothing to translate is shown as it was said.
nonisolated enum CaptionTarget {
    /// English and the dictation language, then the other two, which are a beta, see
    /// `isBeta(_:for:)`.
    static func choices(for language: DictationLanguage) -> [TranslationTarget] {
        language.translationTargets + TranslationTarget.allCases.filter { !language.translationTargets.contains($0) }
    }

    /// Whether `target` is a beta for a user who dictates in `language`: a target that is
    /// neither English nor that language, which a meeting in the dictation language reaches
    /// through English, see `hops(from:into:)`.
    static func isBeta(_ target: TranslationTarget, for language: DictationLanguage) -> Bool {
        !language.translationTargets.contains(target)
    }

    // MARK: Reading a sentence

    /// The language of a caption sentence by its script, whatever the dictation language, or
    /// nil when it is shown as it was said: it has no letter, or it is in a language other
    /// than the four.
    /// - Letters of other scripts, such as Hangul, from LanguageGuard.otherScriptShare of all
    ///   letters on: none of the four.
    /// - Kana: the rule of Japanese dictation, see TranslationDirection.japaneseSource(of:),
    ///   which reads Japanese, or English with a few kana, such as "Let's meet at the カフェ."
    /// - Han characters without kana: the rule of Chinese dictation, see
    ///   TranslationDirection.sourceLanguage(of:), which reads Chinese, or English with a
    ///   name in Han characters. Japanese written in Han characters only reads as Chinese,
    ///   which is rare in speech.
    /// - Latin letters only: the rule of Spanish dictation, see
    ///   TranslationDirection.spanishSource(of:), which reads Spanish or English, when
    ///   NLLanguageRecognizer finds English or Spanish, or when the text is too short for
    ///   it, under LanguageGuard.minimumLatinLetters letters, such as OK, Hi, Sí or Claro.
    ///   Longer text in another language, such as French or Portuguese, is none of the
    ///   four. A short English line with a word that looks Spanish, such as "Hay fever.",
    ///   reads as Spanish, see CaptionPipeline for how it still reaches the target.
    /// Measured on 2026-10-19 on 4,130 texts, it read every FLEURS sentence in Chinese,
    /// Japanese, Spanish and English and every caption of Chinese, Cantonese, mixed,
    /// English, Japanese and Spanish speech in its language, and took 681 French and
    /// Portuguese sentences for none of the four. May run NLLanguageRecognizer, so the
    /// pipeline calls it off the main actor, see CaptionPipeline.shownText.
    static func language(of text: String) -> TranslationTarget? {
        var han = 0
        var kana = 0
        var latin = 0
        var other = 0
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars where scalar.properties.isAlphabetic {
            if LanguageGuard.isHan(scalar) {
                han += 1
            } else if LanguageGuard.isKana(scalar) {
                kana += 1
            } else if LanguageGuard.isLatin(scalar) {
                latin += 1
            } else if scalar.properties.generalCategory.isLetter {
                other += 1
            }
        }
        let letters = han + kana + latin + other
        guard letters > 0, Double(other) < Double(letters) * LanguageGuard.otherScriptShare else { return nil }
        if kana > 0 {
            return switch TranslationDirection.japaneseSource(of: text) {
            case .partner: .japanese
            case .english: .english
            case .other, nil: nil
            }
        }
        if han > 0 {
            return TranslationDirection.sourceLanguage(of: text)
        }
        guard latin < LanguageGuard.minimumLatinLetters || isEnglishOrSpanish(text) else { return nil }
        return switch TranslationDirection.spanishSource(of: text) {
        case .partner: .spanish
        case .english: .english
        case .other, nil: nil
        }
    }

    /// Whether NLLanguageRecognizer, free to choose any language, finds English or Spanish
    /// the most likely.
    private static func isEnglishOrSpanish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english || recognizer.dominantLanguage == .spanish
    }

    // MARK: Routes

    /// A sentence's language and the target.
    struct Pair: Hashable, Sendable {
        let source: TranslationTarget
        let target: TranslationTarget

        init(_ source: TranslationTarget, _ target: TranslationTarget) {
            self.source = source
            self.target = target
        }
    }

    /// How a sentence goes from each language into each other one: the routes it takes in
    /// turn, each translating what the one before wrote. Between English and another
    /// language the route of that language, as for a dictation. Between two of Chinese,
    /// Japanese and Spanish the route into English and then the route from English, each
    /// with its checks, a beta that takes about twice as long as one route. This table is
    /// the one place that chooses, so a pair can move to a direct route of its own later.
    static let table: [Pair: [TranslationRoute]] = {
        let zhEn = TranslationRoute(.chinese, into: .english)
        let jaEn = TranslationRoute(.japanese, into: .english)
        let esEn = TranslationRoute(.spanish, into: .english)
        let enZh = TranslationRoute(.chinese, into: .chinese)
        let enJa = TranslationRoute(.japanese, into: .japanese)
        let enEs = TranslationRoute(.spanish, into: .spanish)
        return [
            Pair(.chinese, .english): [zhEn],
            Pair(.japanese, .english): [jaEn],
            Pair(.spanish, .english): [esEn],
            Pair(.english, .chinese): [enZh],
            Pair(.english, .japanese): [enJa],
            Pair(.english, .spanish): [enEs],
            Pair(.chinese, .japanese): [zhEn, enJa],
            Pair(.chinese, .spanish): [zhEn, enEs],
            Pair(.japanese, .chinese): [jaEn, enZh],
            Pair(.japanese, .spanish): [jaEn, enEs],
            Pair(.spanish, .chinese): [esEn, enZh],
            Pair(.spanish, .japanese): [esEn, enJa],
        ]
    }()

    /// The routes a sentence in `source` takes into `target`, see `table`, and none for a
    /// sentence in the target already or one shown as it was said, a nil `source`.
    static func hops(from source: TranslationTarget?, into target: TranslationTarget) -> [TranslationRoute] {
        source.flatMap { table[Pair($0, target)] } ?? []
    }

    /// Every route a sentence into `target` may take, from any of the other three
    /// languages. Their prefix caches stay while captions run, see TranslationPrefixSlots.
    static func routes(into target: TranslationTarget) -> Set<TranslationRoute> {
        Set(TranslationTarget.allCases.flatMap { hops(from: $0, into: target) })
    }

    /// The routes read ahead while captions run: those of a sentence in English and of one
    /// in the dictation language, the languages a meeting is most likely in, each once. A
    /// sentence in another language fills its route when it comes.
    static func preparedRoutes(into target: TranslationTarget, for language: DictationLanguage) -> [TranslationRoute] {
        var prepared: [TranslationRoute] = []
        for route in hops(from: .english, into: target) + hops(from: language.translationLanguage, into: target) where !prepared.contains(route) {
            prepared.append(route)
        }
        return prepared
    }
}

/// Keeps the caption target in UserDefaults, by the language code of TranslationTarget.
///
/// It is saved when the user picks one, in the caption window or in Settings, and once at
/// launch for a user of an earlier version, see `migrate`. Nothing else writes it, so a
/// target that is only the default never turns into a pick. Until a target is saved, it
/// follows the user's own language, see `defaultTarget(ownLanguage:)`, since a wrong
/// caption target costs one click to change.
nonisolated enum CaptionTargetPreference {
    static let defaultsKey = "captionTarget"
    /// Set by the first launch of a version with the caption target, so `migrate` runs
    /// once. Without it a new user, who looks set up from the second launch on, would be
    /// taken for an earlier user then.
    static let migratedKey = "captionTargetMigrated"

    /// The saved target, or nil when none is saved or the saved one is unknown.
    static func saved(in defaults: UserDefaults = .standard) -> TranslationTarget? {
        defaults.string(forKey: defaultsKey).flatMap(TranslationTarget.init(rawValue:))
    }

    static func save(_ target: TranslationTarget, to defaults: UserDefaults = .standard) {
        defaults.set(target.rawValue, forKey: defaultsKey)
    }

    /// The target while none is saved: the user's own language, see OwnLanguage, and
    /// English without one. So a Mac with English first and Chinese second, which shows
    /// Orra in English, reads an English meeting in Chinese, as under Automatic before.
    static func defaultTarget(ownLanguage: DictationLanguage?) -> TranslationTarget {
        ownLanguage?.translationLanguage ?? .english
    }

    /// The target that keeps an earlier user's captions as close as can be to what they
    /// were, when captions translated the way the translation key does: their Translate
    /// into when it is fixed to a language that fits their dictation language, otherwise
    /// their own language when it is English or their dictation language, the two languages
    /// their captions had, otherwise their dictation language. An English meeting then
    /// still comes out in their language, as under Automatic.
    static func earlierTarget(direction: TranslationDirection, language: DictationLanguage, ownLanguage: DictationLanguage?) -> TranslationTarget {
        if direction != .automatic, direction.fits(language) {
            return direction == .english ? .english : language.translationLanguage
        }
        if let own = ownLanguage?.translationLanguage, language.translationTargets.contains(own) {
            return own
        }
        return language.translationLanguage
    }

    /// At the first launch of this version, saves `earlierTarget` for a user who set Orra
    /// up before, see TriggerModePreference.wasSetUpBefore, unless a target is saved.
    /// Runs once, see `migratedKey`. Returns the target it saved, nil when it saved none.
    /// LaunchMigrations runs it at every launch.
    @discardableResult
    static func migrate(setUpBefore: Bool, direction: TranslationDirection, language: DictationLanguage, ownLanguage: DictationLanguage?, in defaults: UserDefaults = .standard) -> TranslationTarget? {
        guard !defaults.bool(forKey: migratedKey) else { return nil }
        defaults.set(true, forKey: migratedKey)
        guard setUpBefore, saved(in: defaults) == nil else { return nil }
        let target = earlierTarget(direction: direction, language: language, ownLanguage: ownLanguage)
        save(target, to: defaults)
        return target
    }
}
