import Foundation

/// A word the speech model wrote one way and the user changed to another, such as
/// "克劳德" to "Claude".
nonisolated struct Correction: Codable, Equatable, Hashable, Sendable {
    var heard: String
    var corrected: String
}

/// A fix the user made in dictated text: a misheard word Orra learns on its own, or a word
/// it offers to add after a fix of one Chinese character.
nonisolated enum Finding: Equatable, Hashable, Sendable {
    case word(Correction)
    case suggestion(WordSuggestion)

    /// The word pair, as heard and as corrected.
    var correction: Correction {
        switch self {
        case .word(let correction): correction
        case .suggestion(let suggestion): suggestion.pair
        }
    }

    /// Whether this is a word Orra learns on its own.
    var isWord: Bool {
        if case .word = self { true } else { false }
    }
}

/// Finds the corrections a user made in dictated text, from the field's text right after
/// the paste and a little later. Pure, so tests can feed it text.
nonisolated enum CorrectionFinder {
    /// The longest a heard or corrected word may be, in characters.
    static let maximumLength = 12
    /// Above this many character pairs the two texts are not compared character by
    /// character, and the whole changed span is judged as one edit.
    static let maximumComparison = 250_000

    /// One changed stretch: where it is in the pasted text and in the edited text.
    struct Hunk: Equatable, Sendable {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// The fixes in a field that changed from `before` to `after` in one step, as tests and
    /// simple callers see it. The watcher follows the paste over many readings with
    /// PasteTracker instead.
    static func findings(pasted: String, before: String, after: String) -> [Finding] {
        guard var tracker = PasteTracker(pasted: pasted, field: before) else { return [] }
        tracker.update(to: after)
        return findings(pasted: pasted, edited: tracker.pasteNow)
    }

    /// What each separate edit that turned the pasted text into `edited` calls for, in the
    /// order of the text: a word to learn, or after a fix of one Chinese character, a word
    /// to offer. Edits with at least two unchanged characters between them, or a space or
    /// a punctuation mark, are judged on their own, so fixing a name and a particle in the
    /// same sentence learns the name only. An edit is skipped when it is a deletion or an
    /// addition, a rewrite, a change of case or word ending, digits, grammar, too long, or
    /// a change that does not sound alike.
    static func findings(pasted: String, edited editedText: String) -> [Finding] {
        let paste = Array(pasted)
        var edited = Array(editedText)
        guard !paste.isEmpty else { return [] }
        // Punctuation or spaces typed right after the paste, such as a closing period.
        while edited.count > paste.count, let last = edited.last, isSeparator(last), paste.last.map({ !isSeparator($0) }) ?? true {
            edited.removeLast()
        }
        guard edited != paste else { return [] }
        let hunks = hunks(paste, edited)
        var found: [Finding] = []
        for (index, hunk) in hunks.enumerated() {
            // The unchanged text around the edit, up to the edits next to it, in the edited
            // text. A guessed word stays inside it.
            let lower = index > 0 ? hunks[index - 1].new.upperBound : 0
            let upper = index + 1 < hunks.count ? hunks[index + 1].new.lowerBound : edited.count
            if let finding = judge(hunk, paste, edited, within: lower..<upper) {
                found.append(finding)
            }
        }
        return found
    }

    /// The separate edits between the two texts. Characters kept by the longest common
    /// subsequence split the changed span into edits. Edits closer than two characters
    /// without a space or punctuation between them are one edit, and a Latin word is taken
    /// whole, with its digits and joining marks, so SGLang-Omni and Qwen3 stay one word,
    /// and a letter typed into Ora or taken out of it changes the whole word. When less
    /// than half of the pasted text is kept, the text was rewritten, and the whole changed
    /// span is one edit.
    static func hunks(_ paste: [Character], _ edited: [Character]) -> [Hunk] {
        var prefix = 0
        while prefix < paste.count, prefix < edited.count, paste[prefix] == edited[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < paste.count - prefix, suffix < edited.count - prefix,
              paste[paste.count - 1 - suffix] == edited[edited.count - 1 - suffix] { suffix += 1 }
        let whole = Hunk(old: prefix..<(paste.count - suffix), new: prefix..<(edited.count - suffix))
        var hunks = [whole]
        let old = Array(paste[whole.old])
        let new = Array(edited[whole.new])
        if old.count * new.count <= maximumComparison {
            let kept = commonCharacters(old, new)
            if (prefix + suffix + kept.count) * 2 >= paste.count {
                hunks = []
                var position = (old: 0, new: 0)
                for match in kept + [(old: old.count, new: new.count)] {
                    if match.old > position.old || match.new > position.new {
                        hunks.append(Hunk(old: (prefix + position.old)..<(prefix + match.old),
                                          new: (prefix + position.new)..<(prefix + match.new)))
                    }
                    position = (match.old + 1, match.new + 1)
                }
            }
        }
        // Edits one plain character apart are one edit, as 力热吧 and 丽热巴 are.
        var merged: [Hunk] = []
        for hunk in hunks {
            if let last = merged.last {
                let gap = paste[last.old.upperBound..<hunk.old.lowerBound]
                if gap.count < 2, !gap.contains(where: isSeparator) {
                    merged[merged.count - 1] = Hunk(old: last.old.lowerBound..<hunk.old.upperBound,
                                                    new: last.new.lowerBound..<hunk.new.upperBound)
                    continue
                }
            }
            merged.append(hunk)
        }
        return wholeLatinWords(merged, paste, edited)
    }

    /// The positions of the characters both texts keep, as pairs of offsets, earliest
    /// first: a longest common subsequence.
    private static func commonCharacters(_ old: [Character], _ new: [Character]) -> [(old: Int, new: Int)] {
        let columns = new.count + 1
        // length[i * columns + j]: the longest common subsequence of old[i...] and new[j...].
        var length = [Int](repeating: 0, count: (old.count + 1) * columns)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                length[i * columns + j] = old[i] == new[j]
                    ? length[(i + 1) * columns + j + 1] + 1
                    : max(length[(i + 1) * columns + j], length[i * columns + j + 1])
            }
        }
        var kept: [(old: Int, new: Int)] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                kept.append((i, j))
                i += 1
                j += 1
            } else if length[(i + 1) * columns + j] >= length[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return kept
    }

    /// Widens each edit to the whole Latin words it touches, and joins edits that turn out
    /// to be in the same word.
    private static func wholeLatinWords(_ hunks: [Hunk], _ paste: [Character], _ edited: [Character]) -> [Hunk] {
        var hunks = hunks
        var joined = true
        while joined {
            joined = false
            for index in hunks.indices {
                let lower = index > 0 ? hunks[index - 1].old.upperBound : 0
                let upper = index + 1 < hunks.count ? hunks[index + 1].old.lowerBound : paste.count
                let hunk = hunks[index]
                var (oldStart, newStart, oldEnd, newEnd) = (hunk.old.lowerBound, hunk.new.lowerBound, hunk.old.upperBound, hunk.new.upperBound)
                while oldStart > lower, isNamePart(paste[oldStart - 1]),
                      (oldStart < oldEnd && isNamePart(paste[oldStart])) || (newStart < newEnd && isNamePart(edited[newStart])) {
                    oldStart -= 1
                    newStart -= 1
                }
                while oldEnd < upper, isNamePart(paste[oldEnd]),
                      (oldEnd > oldStart && isNamePart(paste[oldEnd - 1])) || (newEnd > newStart && isNamePart(edited[newEnd - 1])) {
                    oldEnd += 1
                    newEnd += 1
                }
                hunks[index] = Hunk(old: oldStart..<oldEnd, new: newStart..<newEnd)
            }
            var result: [Hunk] = []
            for hunk in hunks {
                if let last = result.last, last.old.upperBound == hunk.old.lowerBound,
                   endsInNamePart(last, paste, edited), startsWithNamePart(hunk, paste, edited) {
                    result[result.count - 1] = Hunk(old: last.old.lowerBound..<hunk.old.upperBound,
                                                    new: last.new.lowerBound..<hunk.new.upperBound)
                    joined = true
                } else {
                    result.append(hunk)
                }
            }
            hunks = result
        }
        return hunks
    }

    /// Whether the edit ends in a name part. An edit that only deletes, such as the space
    /// in quen 3, ends where the edited text goes on before it.
    private static func endsInNamePart(_ hunk: Hunk, _ paste: [Character], _ edited: [Character]) -> Bool {
        let last = hunk.new.upperBound - 1
        return (!hunk.old.isEmpty && isNamePart(paste[hunk.old.upperBound - 1]))
            || (edited.indices.contains(last) && isNamePart(edited[last]))
    }

    /// Whether the edit starts with a name part. An edit that only deletes starts where the
    /// edited text goes on after it.
    private static func startsWithNamePart(_ hunk: Hunk, _ paste: [Character], _ edited: [Character]) -> Bool {
        let first = hunk.new.lowerBound
        return (!hunk.old.isEmpty && isNamePart(paste[hunk.old.lowerBound]))
            || (edited.indices.contains(first) && isNamePart(edited[first]))
    }

    /// What one edit calls for. One changed Chinese character is too little to tell a name
    /// from grammar, such as 的 and 得, and the system cannot split an unknown name into
    /// words, so OneCharacterFix offers such a word to the user instead.
    private static func judge(_ hunk: Hunk, _ paste: [Character], _ edited: [Character], within bounds: Range<Int>) -> Finding? {
        if hunk.old.count == 1, hunk.new.count == 1, isHan(paste[hunk.old.lowerBound]), isHan(edited[hunk.new.lowerBound]) {
            return OneCharacterFix.suggestion(paste: paste, edited: edited, at: hunk.old.lowerBound, hunk.new.lowerBound, within: bounds)
                .map(Finding.suggestion)
        }
        let heard = String(paste[hunk.old]).trimmingCharacters(in: .whitespaces)
        let corrected = String(edited[hunk.new]).trimmingCharacters(in: .whitespaces)
        guard isWordLike(heard), isWordLike(corrected),
              heard.count <= maximumLength, corrected.count <= maximumLength,
              hanCount(heard) != 1, hanCount(corrected) != 1,
              !differsOnlyInFirstLetterCase(heard, corrected),
              !differsOnlyInEnding(heard, corrected),
              SoundAlike.soundsAlike(heard, corrected) else { return nil }
        return .word(Correction(heard: heard, corrected: corrected))
    }

    private static func isLatin(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    /// Letters, digits and the marks that join a name, as in SGLang-Omni, Node.js, GPT-4o.
    private static func isNamePart(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_.+".contains(character))
    }

    /// apple and Apple: the start of a sentence, not a name. A name's own capitals, such as
    /// sglang and SGLang, count.
    private static func differsOnlyInFirstLetterCase(_ first: String, _ second: String) -> Bool {
        guard first != second, first.lowercased() == second.lowercased() else { return first == second }
        return first.dropFirst() == second.dropFirst()
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

    /// A word or a name: some letters, no punctuation but the marks that join a name, and
    /// no run of three digits or more, so codes, amounts and years are never kept. Names
    /// such as Qwen3 and GPT-4o pass. Chinese numerals such as 千 and 万 are letters here.
    private static func isWordLike(_ text: String) -> Bool {
        guard text.contains(where: \.isLetter), !text.contains(where: \.isNewline) else { return false }
        var digitRun = 0
        for character in text {
            let isDigit = character.unicodeScalars.contains { $0.properties.numericType == .decimal }
            digitRun = isDigit ? digitRun + 1 : 0
            if digitRun >= 3 { return false }
            if !isDigit, character.isPunctuation || character.isSymbol, !"-_.+".contains(character) { return false }
        }
        return true
    }

    /// cloud and clouds, work and worked: grammar, not a misheard word.
    private static func differsOnlyInEnding(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased()
        let b = second.lowercased()
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard long.hasPrefix(short) else { return false }
        return ["s", "es", "ed", "d", "ing", "'s", "er", "ly"].contains(String(long.dropFirst(short.count)))
    }

}

/// Follows where the pasted text is in a field while the user edits it. Each reading is
/// compared with the one before: an edit before the paste moves it, an edit after it leaves
/// it alone, and an edit inside it changes the pasted text. So typing or fixing other lines
/// in the same field does not lose the paste.
nonisolated struct PasteTracker: Equatable, Sendable {
    private(set) var field: [Character]
    private(set) var range: Range<Int>

    /// Nil when the pasted text is not in the field.
    init?(pasted: String, field text: String) {
        let paste = Array(pasted)
        let characters = Array(text)
        guard !paste.isEmpty, paste.count <= characters.count else { return nil }
        guard let start = stride(from: characters.count - paste.count, through: 0, by: -1)
            .first(where: { characters[$0..<($0 + paste.count)].elementsEqual(paste) }) else { return nil }
        field = characters
        range = start..<(start + paste.count)
    }

    /// The pasted text as it is now.
    var pasteNow: String {
        String(field[range])
    }

    mutating func update(to text: String) {
        let new = Array(text)
        guard new != field else { return }
        var prefix = 0
        while prefix < field.count, prefix < new.count, field[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < field.count - prefix, suffix < new.count - prefix,
              field[field.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldEnd = field.count - suffix
        let newEnd = new.count - suffix
        let shift = newEnd - oldEnd
        if oldEnd <= range.lowerBound {
            // Before the paste.
            range = (range.lowerBound + shift)..<(range.upperBound + shift)
        } else if prefix >= range.upperBound {
            // After the paste, a closing period typed right after it included.
        } else {
            // Inside the paste, or across its edge.
            let lower = min(range.lowerBound, prefix)
            let upper = max(range.upperBound + shift, newEnd)
            range = lower..<max(lower, min(upper, new.count))
        }
        field = new
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

/// The corrections Orra saw, and whether each was learned, undone, or offered and declined. A pair stays seen
/// while its word could not be added, such as when the vocabulary is full. Kept as a small
/// JSON file on this Mac. Holds the word pairs only, never the text around them.
nonisolated struct CorrectionStore: Codable, Equatable, Sendable {
    nonisolated enum State: String, Codable, Sendable {
        case seen
        case accepted
        case dismissed
        /// Offered after a fix of one Chinese character, and closed without adding it. The
        /// same pair is not offered again for 7 days, and its word may still be learned
        /// another way.
        case declined
    }

    struct Entry: Codable, Equatable, Sendable {
        var correction: Correction
        var count: Int
        var lastSeen: Date
        var state: State
    }

    static let window: TimeInterval = 7 * 24 * 60 * 60

    private(set) var entries: [Entry] = []

    /// Counts a correction. A count older than 7 days starts over, and pairs seen once and
    /// not again within 7 days are forgotten, as are pairs declined more than 7 days ago.
    mutating func record(_ correction: Correction, at date: Date) {
        entries.removeAll {
            ($0.state == .seen || $0.state == .declined) && $0.correction != correction
                && date.timeIntervalSince($0.lastSeen) > Self.window
        }
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

    /// Accepts the pairs for the word that were only seen so far, and gives them. Leaves the
    /// pairs the user undid alone.
    mutating func acceptSeen(of word: String) -> [Correction] {
        var accepted: [Correction] = []
        for index in entries.indices where entries[index].correction.corrected == word && entries[index].state == .seen {
            entries[index].state = .accepted
            accepted.append(entries[index].correction)
        }
        return accepted
    }

    /// Forgets a pair, unless the user undid or declined it. For a half typed fix that the
    /// finished one replaces.
    mutating func forget(_ correction: Correction) {
        entries.removeAll { $0.correction == correction && $0.state != .dismissed && $0.state != .declined }
    }

    /// The state of a pair, nil when it was not seen.
    func state(of correction: Correction) -> State? {
        entries.first { $0.correction == correction }?.state
    }

    /// Marks a pair the user was offered and did not add, so it is not offered again.
    mutating func decline(_ correction: Correction) {
        for index in entries.indices where entries[index].correction == correction && entries[index].state == .seen {
            entries[index].state = .declined
        }
    }

    /// Whether any pair for the word has this state.
    func has(_ state: State, for word: String) -> Bool {
        entries.contains { $0.correction.corrected == word && $0.state == state }
    }

    /// Marks the pairs as undone, so their word is not learned again.
    mutating func dismiss(_ corrections: [Correction]) {
        for index in entries.indices where corrections.contains(entries[index].correction) {
            entries[index].state = .dismissed
        }
    }

    mutating func removeAll() {
        entries = []
    }

    /// The stored pairs. A file that cannot be read is moved aside to corrections.json.bad,
    /// so learned and undone pairs are not lost by overwriting it.
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
