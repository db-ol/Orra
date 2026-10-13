import Foundation

/// The language a dictation is translated into.
nonisolated enum TranslationTarget: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    /// For the log.
    var logName: String {
        switch self {
        case .english: "English"
        case .chinese: "Chinese"
        }
    }
}

/// Which way a dictation is translated: chosen from the text by default, or fixed to one
/// target by a setting.
nonisolated enum TranslationDirection: String, CaseIterable, Sendable {
    case automatic
    case english
    case chinese

    static let defaultsKey = "translationDirection"

    static func load(from defaults: UserDefaults = .standard) -> TranslationDirection {
        defaults.string(forKey: defaultsKey).flatMap(TranslationDirection.init(rawValue:)) ?? .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// The target for a text, or nil when it has no Han character and no Latin letter, so
    /// there is nothing to translate and the model is not run.
    func target(for text: String) -> TranslationTarget? {
        guard let source = Self.sourceLanguage(of: text) else { return nil }
        switch self {
        case .automatic: return source == .chinese ? .english : .chinese
        case .english: return .english
        case .chinese: return .chinese
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
