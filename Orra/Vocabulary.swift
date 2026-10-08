import Foundation

/// The user's own words and names, which the speech model gets with every dictation so it
/// writes them the way the user does. Measured on 2026-10-08 with ContextEvaluationTests:
/// on synthetic speech, terms in the vocabulary were recognized 98.9% of the time in
/// Chinese and 95.7% in English, against 84.5% and 83.1% without, and terms that were not
/// spoken were almost never inserted.
nonisolated enum Vocabulary {
    /// At most this many terms reach the model. Every term lengthens the prompt of every
    /// dictation.
    static let limit = 100
    /// Longer lines are cut, since a term is a word or a name, not a sentence.
    static let maximumLength = 40

    /// The terms in text with one term per line: trimmed, without empty lines, each term
    /// once ignoring case, and no more than `limit`.
    static func terms(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let term = String(line.trimmingCharacters(in: .whitespaces).prefix(maximumLength))
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == limit { break }
        }
        return result
    }

    /// What the model gets: one term per line, as the evaluation measured, and nothing
    /// else, since instructions in the prompt can end up in the text. Nil without terms.
    static func context(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.joined(separator: "\n")
    }
}

/// Keeps the vocabulary in UserDefaults, on this Mac only.
nonisolated enum VocabularyPreference {
    static let defaultsKey = "vocabulary"

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        Vocabulary.terms(from: (defaults.stringArray(forKey: defaultsKey) ?? []).joined(separator: "\n"))
    }

    static func save(_ terms: [String], to defaults: UserDefaults = .standard) {
        defaults.set(terms, forKey: defaultsKey)
    }
}
