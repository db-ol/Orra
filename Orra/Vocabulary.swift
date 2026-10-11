import AppKit
import Observation
import os

/// One word or name of the vocabulary, with when it was added and when a pasted transcript
/// last held it. Holds the word and the two dates, never any other text.
nonisolated struct VocabularyWord: Codable, Equatable, Hashable, Sendable, Identifiable {
    var text: String
    var added: Date
    /// When a pasted transcript last held the word, ignoring case. Nil until then.
    var lastUsed: Date?

    init(_ text: String, added: Date, lastUsed: Date? = nil) {
        self.text = text
        self.added = added
        self.lastUsed = lastUsed
    }

    /// The word ignoring case, which is unique in the list.
    var id: String { text.lowercased() }

    /// When the word was added or last used, whichever is later.
    var lastActive: Date { max(added, lastUsed ?? added) }
}

/// The user's own words and names. The speech model gets the most relevant of them with
/// every dictation, so it writes them the way the user does. Measured on 2026-10-08 with
/// ContextEvaluationTests: on synthetic speech, terms in the vocabulary were recognized
/// 98.9% of the time in Chinese and 95.7% in English, against 84.5% and 83.1% without, and
/// terms that were not spoken were almost never inserted into speech. Without speech it is
/// different: in silence, hum or faint noise the model can answer with terms of the list,
/// see VocabularyEcho, so such a transcript is checked once more without the vocabulary.
///
/// A longer list helps less per term and slows every dictation. Measured on 2026-10-10 with
/// Qwen3-ASR 1.7B, spoken terms were recognized 95% of the time with 100 terms in the
/// context, 92 to 93% with 200, 90% with 400 and 87% with 800, and each 1000 tokens of
/// context, about 210 terms, added 0.25 to 0.3 s to every short dictation. So the list
/// itself has no practical limit, and the model gets the `modelLimit` words added or used
/// most recently, see `forModel(_:)`.
nonisolated enum Vocabulary {
    /// At most this many words reach the model with a dictation.
    static let modelLimit = 200
    /// A sanity cap against runaway data, such as a script adding words in a loop. Far
    /// more than a person keeps, so it is not a limit anyone should meet.
    static let maximumCount = 5_000
    /// Longer lines are cut, since a term is a word or a name, not a sentence.
    static let maximumLength = 40

    /// The terms in text with one term per line: trimmed, without empty lines, each term
    /// once ignoring case, and no more than `maximumCount`.
    static func terms(from text: String) -> [String] {
        terms(from: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// The terms trimmed and cut like typed lines, each once ignoring case, without empty
    /// ones, and no more than `maximumCount`.
    static func terms(from lines: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            guard let term = cleaned(line), seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == maximumCount { break }
        }
        return result
    }

    /// A line as a term: trimmed and cut at `maximumLength`. Nil when nothing is left.
    static func cleaned(_ line: String) -> String? {
        let term = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
            .trimmingCharacters(in: .whitespaces)
        return term.isEmpty || term.contains(where: \.isNewline) ? nil : term
    }

    /// The list with one more word, trimmed and cut like a typed line, added at `date`.
    /// Unchanged when the word is empty, already there ignoring case, or the list holds
    /// `maximumCount` words.
    static func adding(_ term: String, to words: [VocabularyWord], at date: Date) -> [VocabularyWord] {
        guard let term = cleaned(term), words.count < maximumCount,
              !contains(term, in: words) else { return words }
        return words + [VocabularyWord(term, added: date)]
    }

    /// Whether the list holds the term, ignoring case.
    static func contains(_ term: String, in words: [VocabularyWord]) -> Bool {
        let id = term.lowercased()
        return words.contains { $0.id == id }
    }

    /// The copied text when it can be a vocabulary word: one line, at most
    /// `maximumLength` characters once trimmed, and not in the list yet. Nil otherwise.
    static func candidate(fromClipboard text: String?, in terms: [String]) -> String? {
        guard let text else { return nil }
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= maximumLength, !term.contains(where: \.isNewline),
              !terms.contains(where: { $0.lowercased() == term.lowercased() }) else { return nil }
        return term
    }

    /// The list without the terms, ignoring case.
    static func removing(_ terms: some Sequence<String>, from words: [VocabularyWord]) -> [VocabularyWord] {
        let ids = Set(terms.map { $0.lowercased() })
        return words.filter { !ids.contains($0.id) }
    }

    /// The words the model gets: the `limit` added or used most recently, a word added
    /// later first when two are equally recent, in the order of the list. Manual and
    /// learned words count the same.
    static func forModel(_ words: [VocabularyWord], limit: Int = modelLimit) -> [String] {
        guard words.count > limit else { return words.map(\.text) }
        let chosen = Set(words.indices.sorted { a, b in
            let (first, second) = (words[a].lastActive, words[b].lastActive)
            return first != second ? first > second : a > b
        }.prefix(limit))
        return words.indices.filter(chosen.contains).map { words[$0].text }
    }

    /// The list with `date` as the last use of each word the transcript holds, ignoring
    /// case. A word that starts or ends with a Latin letter or digit counts only where
    /// the transcript has no Latin letter or digit right next to it, so "Orra" is not used
    /// in "Orrange". Keeps nothing of the transcript.
    static func markingUsed(in transcript: String, _ words: [VocabularyWord], at date: Date) -> [VocabularyWord] {
        words.map { word in
            guard holds(transcript, word.text) else { return word }
            var used = word
            used.lastUsed = date
            return used
        }
    }

    private static func holds(_ text: String, _ term: String) -> Bool {
        func isLatin(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isASCII && (character.isLetter || character.isNumber)
        }
        let checksStart = isLatin(term.first)
        let checksEnd = isLatin(term.last)
        var searchStart = text.startIndex
        while let range = text.range(of: term, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !(checksStart && isLatin(before)) && !(checksEnd && isLatin(after)) {
                return true
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    /// What the model gets: one term per line, as the evaluation measured, and nothing
    /// else, since instructions in the prompt can end up in the text. Nil without terms.
    static func context(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.joined(separator: "\n")
    }
}

/// Finds transcripts that may only echo the vocabulary. With a vocabulary as context,
/// Qwen3-ASR can answer a hold without speech, in silence, hum or faint noise, with the
/// first term of the list or several terms in list order. Measured on 2026-10-10 with
/// vocabularies of about 5 to 150 terms. Without a vocabulary the same audio gives no text.
/// Such a transcript is made of terms and nothing else, which real speech rarely is, so
/// only then is the audio transcribed again without the vocabulary, see
/// `Transcription.transcribe(_:vocabulary:audioSeconds:)`.
nonisolated enum VocabularyEcho {
    /// True when the text, ignoring case, spaces and punctuation, is one or more terms of
    /// the list in any order, each possibly repeated. A last term may be cut short, as when
    /// the model ran out of tokens, once at least one whole term came before it. False for
    /// text without letters or digits and for an empty list.
    static func isOnlyTerms(_ text: String, of terms: [String]) -> Bool {
        let heard = Array(normalized(text).unicodeScalars)
        let keys = Set(terms.map(normalized)).filter { !$0.isEmpty }.map { Array($0.unicodeScalars) }
        guard !heard.isEmpty, !keys.isEmpty else { return false }
        // reachable[i]: the first i scalars are whole terms.
        var reachable = [Bool](repeating: false, count: heard.count + 1)
        reachable[0] = true
        for start in 0..<heard.count where reachable[start] {
            let rest = heard[start...]
            for key in keys {
                if rest.starts(with: key) {
                    reachable[start + key.count] = true
                } else if start > 0, key.starts(with: rest) {
                    return true
                }
            }
        }
        return reachable[heard.count]
    }

    /// Lowercase letters and digits only, without accents, full width Latin as ASCII and
    /// traditional characters as simplified, so "I R S transcripts。" matches the term "IRS
    /// transcripts". Traditional characters are converted even in mostly English text, since
    /// this only compares text with terms.
    static func normalized(_ text: String) -> String {
        let folded = ChineseText.simplifiedCharacters(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }
}

/// Keeps the vocabulary in UserDefaults, on this Mac only: the words with their dates as
/// JSON under `defaultsKey`. Orra 0.1.0 kept the words alone as a string array under
/// `legacyKey`. Those are taken over once, dated the moment they are, and the old value is
/// left as it was, so going back to 0.1.0 still finds the words it knew.
nonisolated enum VocabularyPreference {
    static let defaultsKey = "vocabularyWords"
    static let legacyKey = "vocabulary"

    static func load(from defaults: UserDefaults = .standard, now: Date = Date()) -> [VocabularyWord] {
        if let data = defaults.data(forKey: defaultsKey) {
            if let words = try? JSONDecoder().decode([VocabularyWord].self, from: data) {
                return cleaned(words)
            }
            // Counts nothing and names no word.
            Logger(subsystem: "io.github.db-ol.Orra", category: "vocabulary").error("The saved vocabulary could not be read, using the older list")
        }
        return Vocabulary.terms(from: defaults.stringArray(forKey: legacyKey) ?? []).map {
            VocabularyWord($0, added: now)
        }
    }

    static func save(_ words: [VocabularyWord], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(words) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The saved words trimmed and cut, each once ignoring case, at most `maximumCount`.
    private static func cleaned(_ words: [VocabularyWord]) -> [VocabularyWord] {
        var seen = Set<String>()
        var result: [VocabularyWord] = []
        for word in words {
            guard let text = Vocabulary.cleaned(word.text), seen.insert(text.lowercased()).inserted else { continue }
            var kept = word
            kept.text = text
            result.append(kept)
            if result.count == Vocabulary.maximumCount { break }
        }
        return result
    }
}

/// What happened when a word was added to the vocabulary.
enum VocabularyAddition: Equatable {
    case added
    case alreadyThere
    /// The list holds `Vocabulary.maximumCount` words, the sanity cap.
    case full
}

/// The copied word the menu offers to add to the vocabulary. Read once each time a menu
/// opens, never while Orra dictates: the paste reads and restores the pasteboard off the
/// main thread then, and NSPasteboard must not be used from two threads at once.
@Observable
final class ClipboardWord {
    /// The copied text, when it can be a vocabulary word.
    private(set) var word: String?

    @ObservationIgnored private let read: () -> String?
    @ObservationIgnored private let isDictating: () -> Bool
    @ObservationIgnored private let vocabulary: () -> [String]
    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?

    init(read: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
         isDictating: @escaping () -> Bool,
         vocabulary: @escaping () -> [String]) {
        self.read = read
        self.isDictating = isDictating
        self.vocabulary = vocabulary
    }

    func refresh() {
        let terms = vocabulary()
        guard !isDictating(), terms.count < Vocabulary.maximumCount else {
            word = nil
            return
        }
        word = Vocabulary.candidate(fromClipboard: read(), in: terms)
    }

    /// Forgets the word once it was added.
    func clear() {
        word = nil
    }

    func refreshWhenMenusOpen() {
        guard menuObserver == nil else { return }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }
}
