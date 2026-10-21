import Foundation

/// The language a dictation is translated into: English, or the user's dictation language,
/// see DictationLanguage.translationLanguage.
nonisolated enum TranslationTarget: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"
    case spanish = "es"

    /// For the log.
    var logName: String {
        switch self {
        case .english: "English"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .spanish: "Spanish"
        }
    }

    /// The language tag the voice models take, the English name in lowercase, see
    /// Qwen3VoiceEngine.
    var voiceTag: String {
        logName.lowercased()
    }
}

/// Which way a dictation is translated: chosen from the text by default, or fixed to one
/// target by a setting.
///
/// Automatic translates between English and the user's dictation language. A fixed choice
/// may be any of the four languages, whatever the dictation language, see
/// `choices(for:)`. One outside English and the dictation language is Beta and goes through
/// English, see `fits(_:)` and TranslationPlan. Before it was offered, such a choice acted
/// as Automatic, so the first launch that offers it saves Automatic in its place, see
/// `migrate(_:language:in:)`. The functions without a dictation language are those of
/// Chinese, as before the choice.
nonisolated enum TranslationDirection: String, CaseIterable, Sendable {
    case automatic
    case english
    case chinese
    case japanese
    case spanish

    static let defaultsKey = "translationDirection"

    static func load(from defaults: UserDefaults = .standard) -> TranslationDirection {
        defaults.string(forKey: defaultsKey).flatMap(TranslationDirection.init(rawValue:)) ?? .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// The target for a text of a user who dictates in Chinese, or nil when it has no Han
    /// character and no Latin letter, so there is nothing to translate and the model is not
    /// run.
    func target(for text: String) -> TranslationTarget? {
        target(for: text, in: .chinese)
    }

    /// The target for a text of a user who dictates in `language`, or nil when it has no
    /// letter to translate, see `source(of:in:)`. Automatic sends English to the dictation
    /// language and everything else to English, the dictation language and text in neither
    /// language alike. A fixed choice sends everything to its language.
    func target(for text: String, in language: DictationLanguage) -> TranslationTarget? {
        target(source: Self.source(of: text, in: language), in: language)
    }

    /// The same for a text whose language the caller read already.
    func target(source: Source?, in language: DictationLanguage) -> TranslationTarget? {
        guard let source else { return nil }
        return fixedTarget ?? (source == .english ? language.translationLanguage : .english)
    }

    /// The language of a fixed choice, nil for Automatic.
    var fixedTarget: TranslationTarget? {
        switch self {
        case .automatic: nil
        case .english: .english
        case .chinese: .chinese
        case .japanese: .japanese
        case .spanish: .spanish
        }
    }

    /// How the translation key translates a text of a user who dictates in `language`, read
    /// once, or nil when it has no letter to translate. Off the main actor, since the
    /// Spanish rule may run NLLanguageRecognizer. Between English and the dictation
    /// language a text takes one route, as always. Into a language outside that pair it
    /// goes through English, see TranslationPlan. A dictation passes the language it read
    /// on to the steps after it, see TranslationStep. Captions have a plan of their own,
    /// see CaptionTarget.
    @concurrent
    func plan(for text: String, in language: DictationLanguage) async -> TranslationPlan? {
        guard let source = Self.source(of: text, in: language), let target = target(source: source, in: language) else { return nil }
        guard !fits(language) else { return .route(TranslationRoute(language, into: target), source: source) }
        return TranslationPlan.into(target, text: text, source: source, in: language)
    }

    /// Whether the choice stays between English and `language`: Automatic and English for
    /// every dictation language, and the language itself. Any other choice is a target
    /// outside the pair, which goes through English and is Beta.
    func fits(_ language: DictationLanguage) -> Bool {
        self == .automatic || self == .english || self == language.translationDirection
    }

    /// The choices Settings offers for `language`: Automatic, English and the language,
    /// the three there always were, then the other two in the order Chinese, Japanese,
    /// Spanish, as Beta.
    static func choices(for language: DictationLanguage) -> [TranslationDirection] {
        let pair: [TranslationDirection] = [.automatic, .english, language.translationDirection]
        return pair + [.chinese, .japanese, .spanish].filter { !pair.contains($0) }
    }

    // MARK: Targets outside the pair

    /// Set by the first launch of a version that offers every target, so `migrate` runs
    /// once. After it, a choice outside the pair is one the user made.
    static let targetsMigratedKey = "translationDirectionTargetsMigrated"

    /// Before every target was offered, a fixed choice saved for another dictation language
    /// acted as Automatic, so going back to that language brought it back. Now it would
    /// act as its language, and Chinese speech of a user who once picked Japanese while
    /// dictating Japanese would suddenly paste in Japanese. So at the first launch of this
    /// version such a choice is saved as Automatic, which is what it did. Runs once, see
    /// `targetsMigratedKey`. Returns the choice it saved, nil when it saved none.
    /// LaunchMigrations runs it at every launch.
    @discardableResult
    static func migrate(_ direction: TranslationDirection, language: DictationLanguage, in defaults: UserDefaults = .standard) -> TranslationDirection? {
        guard !defaults.bool(forKey: targetsMigratedKey) else { return nil }
        defaults.set(true, forKey: targetsMigratedKey)
        guard !direction.fits(language) else { return nil }
        TranslationDirection.automatic.save(to: defaults)
        return .automatic
    }

    /// The language a text is in, for a user who dictates in `language`.
    nonisolated enum Source: Equatable, Sendable {
        case english
        /// The dictation language.
        case partner
        /// Neither, such as Korean, or Chinese for a user who dictates in Spanish.
        case other
    }

    /// The language of a text for the rule of `language`, or nil when the text has no letter
    /// of any script, such as digits or symbols alone. Chinese keeps the rule of
    /// `sourceLanguage(of:)`. Japanese and Spanish have rules of their own, see
    /// `japaneseSource(of:)` and `spanishSource(of:)`.
    static func source(of text: String, in language: DictationLanguage) -> Source? {
        switch language {
        case .chinese: sourceLanguage(of: text).map { $0 == .chinese ? .partner : .english }
        case .japanese: japaneseSource(of: text)
        case .spanish: spanishSource(of: text)
        }
    }

    /// The language the speaker used, by the rule of the translation benchmark of
    /// 2026-10-12 (direction.py). With h Han characters, L Latin letters, fz Chinese
    /// function characters and fe English function words, the text is Chinese when
    /// h + 2 fz >= L / 5 + 2 fe, and English otherwise. Names and places in the other
    /// language seldom hold function words, so "Send it to 王小明." is English and
    /// "这个 PR 你帮我 review 一下" Chinese. On the 354 labelled cases it was tuned on it
    /// chose wrong once (cm04). Nil without a Han character or a Latin letter.
    static func sourceLanguage(of text: String) -> TranslationTarget? {
        let counts = Counts(text)
        guard counts.han > 0 || counts.letters > 0 else { return nil }
        let chinese = Double(counts.han + 2 * counts.chineseFunction)
        let english = Double(counts.letters) / 5 + Double(2 * counts.englishFunction)
        return chinese >= english ? .chinese : .english
    }

    /// The counts the rule weighs.
    struct Counts: Equatable {
        var han = 0
        var letters = 0
        var chineseFunction = 0
        var englishFunction = 0

        init(_ text: String) {
            for scalar in text.unicodeScalars {
                if TranslationDirection.isHan(scalar) {
                    han += 1
                }
                if ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) {
                    letters += 1
                }
                if TranslationDirection.chineseFunction.contains(scalar) {
                    chineseFunction += 1
                }
            }
            englishFunction = TranslationDirection.words(text).filter { TranslationDirection.englishFunction.contains($0) }.count
        }
    }

    /// Particles, pronouns, the copula and common verbs and adverbs that names and places
    /// almost never hold.
    static let chineseFunction = Set("的了吗吧呢嘛是在我你他她它们这那把给要会能就也都还很没不有说去来和跟让被么啊呀哦个一下得过着再".unicodeScalars)

    /// English function words and interjections.
    static let englishFunction: Set<String> = [
        "the", "a", "an", "to", "is", "are", "was", "were", "be", "it", "its", "i", "you", "we", "they", "he", "she", "my", "your", "our", "their",
        "of", "in", "on", "at", "for", "with", "and", "or", "but", "not", "do", "does", "did", "can", "could", "will", "would", "should",
        "let's", "lets", "this", "that", "me", "him", "her", "us", "them", "from", "by", "about", "please", "what", "how", "why", "when", "where", "if", "so", "just", "have", "has",
        "thanks", "thank", "hi", "hello", "hey", "happy", "yes", "no", "ok", "okay", "sorry",
    ]

    /// Han characters in the ranges direction.py counts: CJK Extension A, the unified
    /// ideographs and the compatibility ideographs.
    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    /// English words in lowercase, with an apostrophe inside a word kept: let's, don’t.
    static func words(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return word.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { text[$0].lowercased() } }
    }

    private static let word = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’][A-Za-z]+)*")
}

/// Whether the user turned translation on, so the translation key pastes translated text.
/// Off until they do.
nonisolated enum TranslationPreference {
    static let defaultsKey = "translatesWithTranslationKey"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey, default: false)
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }

    /// Whether the user turned translation on at least once. The switch starts off and is
    /// saved only when it changes, so a saved value, on or off, says so. Only such a user
    /// could use the translation key, whose mode follows from it, see
    /// TriggerModePreference.
    static func wasTurnedOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) != nil
    }
}
