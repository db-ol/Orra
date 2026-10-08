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
    /// fixing a misheard word: both sides present, short, and sounding alike. Nil for no
    /// edit, an edit outside the pasted text, a deletion or an addition, a rewrite, or
    /// several edits far apart.
    static func correction(pasted: String, before: String, after: String) -> Correction? {
        let old = Array(before)
        let new = Array(after)
        let pastedCharacters = Array(pasted)
        guard !pastedCharacters.isEmpty, old != new,
              let pastedStart = range(of: pastedCharacters, in: old) else { return nil }
        let pastedEnd = pastedStart + pastedCharacters.count
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // The edit, which starts at the same place in both texts.
        var start = prefix
        var oldEnd = old.count - suffix
        var newEnd = new.count - suffix
        // Whole words: an edit that touches a Latin word takes in all of its letters and
        // digits, on both sides, since the text outside the edit is the same in both.
        while start > 0, isWordCharacter(old[start - 1]),
              (start < oldEnd && isWordCharacter(old[start])) || (start < newEnd && isWordCharacter(new[start])) {
            start -= 1
        }
        while oldEnd < old.count, isWordCharacter(old[oldEnd]),
              (oldEnd > start && isWordCharacter(old[oldEnd - 1])) || (newEnd > start && isWordCharacter(new[newEnd - 1])) {
            oldEnd += 1
            newEnd += 1
        }
        guard start >= pastedStart, oldEnd <= pastedEnd, start < oldEnd, start < newEnd else { return nil }
        let heard = String(old[start..<oldEnd]).trimmingCharacters(in: .whitespaces)
        let corrected = String(new[start..<newEnd]).trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !corrected.isEmpty, heard != corrected,
              heard.count <= maximumLength, corrected.count <= maximumLength,
              // An edit that changes half of what was pasted is a rewrite.
              heard.count * 2 <= pastedCharacters.count || pastedCharacters.count <= maximumLength,
              SoundAlike.soundsAlike(heard, corrected) else { return nil }
        return Correction(heard: heard, corrected: corrected)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// Where the pasted text is in the field, the last place if it is there twice.
    private static func range(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in stride(from: haystack.count - needle.count, through: 0, by: -1) where Array(haystack[start..<start + needle.count]) == needle {
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

    /// Edit distance over the sounds, at most 40% of the longer one, or 60% when one side
    /// is Chinese and the other Latin, since pinyin only roughly spells English.
    static func soundsAlike(_ first: String, _ second: String) -> Bool {
        let a = Array(sound(first))
        let b = Array(sound(second))
        guard !a.isEmpty, !b.isEmpty else { return false }
        let crossesScripts = first.unicodeScalars.contains { $0.value >= 0x3400 } != second.unicodeScalars.contains { $0.value >= 0x3400 }
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

    /// Counts a correction. A count older than 7 days starts over.
    mutating func record(_ correction: Correction, at date: Date) {
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

    mutating func removeAll() {
        entries = []
    }

    static func load(from url: URL) -> CorrectionStore {
        guard let data = try? Data(contentsOf: url) else { return CorrectionStore() }
        return (try? JSONDecoder().decode(CorrectionStore.self, from: data)) ?? CorrectionStore()
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
