import Foundation

/// A word the speech model wrote one way and the user changed to another, such as
/// "克劳德" to "Claude".
nonisolated struct Correction: Codable, Equatable, Hashable, Sendable {
    var heard: String
    var corrected: String
}

/// Finds the correction a user made in dictated text, from the field's text right after
/// the paste and a little later. Pure, so tests can feed it text.
nonisolated enum CorrectionFinder {
    /// The longest a heard or corrected word may be, in characters.
    static let maximumLength = 12

    /// The one edit made inside the pasted text, widened to whole words, when it looks like
    /// fixing a misheard word. Nil when the text around the paste changed, for no edit, a
    /// deletion or an addition, a rewrite, a change of case or word ending, digits, or a
    /// change that does not sound alike.
    static func correction(pasted: String, before: String, after: String) -> Correction? {
        let old = Array(before)
        let new = Array(after)
        let paste = Array(pasted)
        guard !paste.isEmpty, let pasteStart = lastRange(of: paste, in: old) else { return nil }
        // The text around the paste must be unchanged, so the edit is inside the paste.
        let head = old[..<pasteStart]
        let tail = old[(pasteStart + paste.count)...]
        guard new.count >= head.count + tail.count, new.starts(with: head), new.reversed().starts(with: tail.reversed()) else { return nil }
        var edited = Array(new[head.count..<(new.count - tail.count)])
        // Punctuation or spaces typed after the pasted text, such as a closing period.
        while edited.count > paste.count, let last = edited.last, isSeparator(last), paste.last.map({ !isSeparator($0) }) ?? true {
            edited.removeLast()
        }
        guard edited != paste else { return nil }
        var prefix = 0
        while prefix < paste.count, prefix < edited.count, paste[prefix] == edited[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < paste.count - prefix, suffix < edited.count - prefix,
              paste[paste.count - 1 - suffix] == edited[edited.count - 1 - suffix] { suffix += 1 }
        var start = prefix
        var oldEnd = paste.count - suffix
        var newEnd = edited.count - suffix
        guard start < oldEnd, start < newEnd else { return nil }
        // A Latin word is taken whole.
        while start > 0, isLatin(paste[start - 1]),
              (start < oldEnd && isLatin(paste[start])) || (start < newEnd && isLatin(edited[start])) {
            start -= 1
        }
        while oldEnd < paste.count, isLatin(paste[oldEnd]),
              (oldEnd > start && isLatin(paste[oldEnd - 1])) || (newEnd > start && isLatin(edited[newEnd - 1])) {
            oldEnd += 1
            newEnd += 1
        }
        let heard = String(paste[start..<oldEnd]).trimmingCharacters(in: .whitespaces)
        let corrected = String(edited[start..<newEnd]).trimmingCharacters(in: .whitespaces)
        guard isWordLike(heard), isWordLike(corrected),
              heard.count <= maximumLength, corrected.count <= maximumLength,
              // One changed Chinese character is too little to tell a name from grammar, such
              // as 的 and 得, and the system cannot split an unknown name into words. Such a
              // word is left for the user to add by hand.
              hanCount(heard) != 1, hanCount(corrected) != 1,
              heard.lowercased() != corrected.lowercased(),
              !differsOnlyInEnding(heard, corrected),
              paste.count <= maximumLength || heard.count * 2 <= paste.count,
              SoundAlike.soundsAlike(heard, corrected) else { return nil }
        return Correction(heard: heard, corrected: corrected)
    }

    private static func isLatin(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    private static func hanCount(_ text: String) -> Int {
        text.filter(isHan).count
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }

    /// Letters only: no digits, so codes and amounts are never kept, no punctuation, and
    /// not empty.
    private static func isWordLike(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { $0.isNumber || $0.isPunctuation || $0.isSymbol || $0.isNewline }
    }

    /// cloud and clouds, work and worked: grammar, not a misheard word.
    private static func differsOnlyInEnding(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased()
        let b = second.lowercased()
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard long.hasPrefix(short) else { return false }
        return ["s", "es", "ed", "d", "ing", "'s", "er", "ly"].contains(String(long.dropFirst(short.count)))
    }

    /// Where the pasted text is in the field, the last place if it is there twice.
    private static func lastRange(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in stride(from: haystack.count - needle.count, through: 0, by: -1)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }
}

/// Whether two words sound alike, so a change between them fixes a misheard word rather
/// than changing what was said. Chinese is compared by its pinyin, from the system's
/// Mandarin to Latin transform, without tones.
nonisolated enum SoundAlike {
    static func sound(_ text: String) -> String {
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(plain.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Within one script: the same first sound, and an edit distance of at most 40% of the
    /// longer sound, so 明天 and 今天 or Monday and Sunday do not pass. Between Chinese and
    /// Latin text, such as 克劳德 and Claude, 60% and any first sound, since pinyin only
    /// roughly spells English.
    static func soundsAlike(_ first: String, _ second: String) -> Bool {
        let a = Array(sound(first))
        let b = Array(sound(second))
        guard let firstA = a.first, let firstB = b.first else { return false }
        let crossesScripts = first.unicodeScalars.contains { $0.value >= 0x3400 } != second.unicodeScalars.contains { $0.value >= 0x3400 }
        if !crossesScripts, firstA != firstB { return false }
        let limit = Double(max(a.count, b.count)) * (crossesScripts ? 0.6 : 0.4)
        return Double(distance(a, b)) <= limit
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let current = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (x == y ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}

/// The corrections Orra saw, and what the user decided about each. Suggests one once it
/// was seen twice within 7 days. Kept as a small JSON file on this Mac. Holds the word
/// pairs only, never the text around them.
nonisolated struct CorrectionStore: Codable, Equatable, Sendable {
    nonisolated enum State: String, Codable, Sendable {
        case seen
        case accepted
        case dismissed
    }

    struct Entry: Codable, Equatable, Sendable {
        var correction: Correction
        var count: Int
        var lastSeen: Date
        var state: State
    }

    static let window: TimeInterval = 7 * 24 * 60 * 60
    static let timesBeforeSuggesting = 2

    private(set) var entries: [Entry] = []

    /// Counts a correction. A count older than 7 days starts over, and pairs seen once and
    /// not again within 7 days are forgotten.
    mutating func record(_ correction: Correction, at date: Date) {
        entries.removeAll { $0.state == .seen && $0.correction != correction && date.timeIntervalSince($0.lastSeen) > Self.window }
        if let index = entries.firstIndex(where: { $0.correction == correction }) {
            if date.timeIntervalSince(entries[index].lastSeen) > Self.window {
                entries[index].count = 0
            }
            entries[index].count += 1
            entries[index].lastSeen = date
        } else {
            entries.append(Entry(correction: correction, count: 1, lastSeen: date, state: .seen))
        }
    }

    /// Seen often enough, and neither added nor ignored yet.
    var suggestions: [Correction] {
        entries.filter { $0.state == .seen && $0.count >= Self.timesBeforeSuggesting }.map(\.correction)
    }

    /// The corrections the user added, which Orra applies before pasting.
    var accepted: [Correction] {
        entries.filter { $0.state == .accepted }.map(\.correction)
    }

    mutating func decide(_ correction: Correction, _ state: State) {
        if let index = entries.firstIndex(where: { $0.correction == correction }) {
            entries[index].state = state
        }
    }

    /// Stops applying an accepted pair and never suggests it again.
    mutating func remove(_ correction: Correction) {
        decide(correction, .dismissed)
    }

    mutating func removeAll() {
        entries = []
    }

    /// The stored pairs. A file that cannot be read is moved aside to corrections.json.bad,
    /// so accepted pairs are not lost by overwriting it.
    static func load(from url: URL) -> CorrectionStore {
        guard let data = try? Data(contentsOf: url) else { return CorrectionStore() }
        if let store = try? JSONDecoder().decode(CorrectionStore.self, from: data) {
            return store
        }
        let aside = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return CorrectionStore()
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Puts the user's accepted corrections into dictated text before the paste.
nonisolated enum Replacements {
    /// Replaces each heard word with its correction. A Latin word must stand alone, so
    /// "cloud" does not change "clouds". Chinese is replaced wherever it appears, for heard
    /// words of 2 characters or more.
    static func apply(_ corrections: [Correction], to text: String) -> String {
        var result = text
        for correction in corrections.sorted(by: { $0.heard.count > $1.heard.count }) {
            let heard = correction.heard
            if heard.allSatisfy({ $0.isASCII }) {
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: heard) + "(?![A-Za-z0-9])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: correction.corrected))
            } else if heard.count >= 2 {
                result = result.replacingOccurrences(of: heard, with: correction.corrected)
            }
        }
        return result
    }
}
