import AppKit
import Observation

/// The user's own words and names, which the speech model gets with every dictation so it
/// writes them the way the user does. Measured on 2026-10-08 with ContextEvaluationTests:
/// on synthetic speech, terms in the vocabulary were recognized 98.9% of the time in
/// Chinese and 95.7% in English, against 84.5% and 83.1% without, and terms that were not
/// spoken were almost never inserted into speech. Without speech it is different: in
/// silence, hum or faint noise the model can answer with terms of the list, see
/// VocabularyEcho, so such a transcript is checked once more without the vocabulary.
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

    /// The list with one more term, trimmed and cut like a typed line. Unchanged when the
    /// term is empty, already there ignoring case, or the list is full.
    static func adding(_ term: String, to terms: [String]) -> [String] {
        Self.terms(from: (terms + [term]).joined(separator: "\n"))
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

    /// The list without the term.
    static func removing(_ term: String, from terms: [String]) -> [String] {
        terms.filter { $0 != term }
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

/// What happened when learning added a word to the vocabulary.
enum VocabularyAddition: Equatable {
    case added
    case alreadyThere
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
        guard !isDictating(), terms.count < Vocabulary.limit else {
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
