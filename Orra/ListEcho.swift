import Foundation

/// Finds a list of names written over speech. With names read from the screen in the
/// context, see ScreenNames, Qwen3-ASR sometimes writes the whole list, or starts with it,
/// in place of what the user said. Measured on 2026-10-15 and 16, with the names merged
/// with a vocabulary of 150 words, this happened in 2 to 6% of dictations, and the list
/// took up to 4.3 s to write. VocabularyEcho alone keeps such a list whenever the pass
/// without the context heard speech, so it would be pasted.
///
/// Three protections, each decided against the pass without the context, which then
/// stands:
/// 1. The text is only terms (VocabularyEcho), the pass without the context heard speech,
///    the two do not sound alike (`soundSimilarity` below 0.5), and one has half again as
///    many words as the other. The length keeps a name said alone that the pass without
///    the context spells in other letters, as 尉迟岚 and 鱼鳍蓝.
/// 2. The text starts with two or more terms in list order, separated only by punctuation,
///    and the pass without the context does not have half of them among its first words.
/// 3. Terms make up 60% or more of the text's words, the pass without the context holds
///    less than half that share and heard speech, and the text has half again as many
///    words. The length keeps a dictation of one or two names, as "Callum."
///
/// On 548 clips with speech in six kinds of context, 16 that only said names and 24
/// without speech, they caught every list seen and never a name said alone. The two
/// length rules were set after seeing the 16 clips of names, so they rest on few clips.
/// A word is a Latin word or a Han character. Text only, so tests need no model.
nonisolated enum ListEcho {
    nonisolated enum Protection: String, Sendable {
        case onlyTermsOverSpeech = "only terms over speech"
        case leadingList = "a leading list"
        case mostlyTerms = "mostly terms"
    }

    /// Protection 1, for a text that is only terms while the pass without the context,
    /// `plain`, heard speech.
    static func isListOverSpeech(_ text: String, plain: String) -> Bool {
        let units = Double(unitCount(text))
        let plainUnits = Double(unitCount(plain))
        let lengthsDiffer = max(units, plainUnits) >= 1.5 * max(1, min(units, plainUnits))
        return soundSimilarity(plain, text) < 0.5 && lengthsDiffer
    }

    /// Whether protection 2 or 3 may apply to a text that is not only terms, so the pass
    /// without the context has to run. Most dictations need no such pass.
    static func mayBeList(_ text: String, terms: [String]) -> Bool {
        leadingItems(text, terms: terms) != nil || termCoverage(text, terms: terms) >= 0.6
    }

    /// Protection 2 or 3, for a text that is not only terms, or nil when neither applies.
    static func protection(_ text: String, plain: String, terms: [String], heardSpeech: Bool) -> Protection? {
        if let items = leadingItems(text, terms: terms), !plainHasItems(plain, items: items) {
            return .leadingList
        }
        let coverage = termCoverage(text, terms: terms)
        if heardSpeech, coverage >= 0.6, termCoverage(plain, terms: terms) < coverage / 2,
           Double(unitCount(text)) >= 1.5 * Double(unitCount(plain)) {
            return .mostlyTerms
        }
        return nil
    }

    // MARK: Sound

    /// 1 less the edit distance of the sound keys (SoundAlike.sound, pinyin without tones
    /// for Han) over the longer key. 0 when either is empty.
    static func soundSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(SoundAlike.sound(a))
        let y = Array(SoundAlike.sound(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 1 - Double(editDistance(x, y)) / Double(max(x.count, y.count))
    }

    /// SoundAlike.soundsAlike, and for a word too short for its English key, the edit
    /// distance of the sound keys alone.
    static func soundsAlike(_ first: String, _ second: String) -> Bool {
        guard SoundAlike.consonants(first) == nil || SoundAlike.consonants(second) == nil else {
            return SoundAlike.soundsAlike(first, second)
        }
        let a = Array(SoundAlike.sound(first))
        let b = Array(SoundAlike.sound(second))
        guard let firstA = a.first, let firstB = b.first else { return false }
        let crossesScripts = first.unicodeScalars.contains { $0.value >= 0x3400 } != second.unicodeScalars.contains { $0.value >= 0x3400 }
        if !crossesScripts, firstA != firstB { return false }
        let limit = Double(max(a.count, b.count)) * (crossesScripts ? 0.6 : 0.4)
        return Double(editDistance(a, b)) <= limit
    }

    // MARK: Leading list

    static let separators: Set<Character> = [",", "，", "、", ";", "；", ".", "。", ":", "："]

    /// The items the text starts with when there are two or more of them in list order,
    /// else nil. An item is a whole term or a word of three letters or more of a Latin term,
    /// compared without case, spaces and punctuation.
    static func leadingItems(_ text: String, terms: [String]) -> [String]? {
        var index: [String: Int] = [:]
        for (i, term) in terms.enumerated() {
            let key = VocabularyEcho.normalized(term)
            if !key.isEmpty, index[key] == nil { index[key] = i }
            let parts = term.split(separator: " ").map(String.init)
            if parts.count > 1, parts.allSatisfy({ $0.allSatisfy(\.isASCII) }) {
                for part in parts where part.count >= 3 {
                    let partKey = VocabularyEcho.normalized(part)
                    if index[partKey] == nil { index[partKey] = i }
                }
            }
        }
        var items: [String] = []
        var current = ""
        for character in text {
            if separators.contains(character) {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        var run: [String] = []
        var last = -1
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let position = index[VocabularyEcho.normalized(trimmed)], position >= last else { break }
            run.append(trimmed)
            last = position
        }
        return run.count >= 2 ? run : nil
    }

    /// Whether at least half of the items sound like a word or a run of words among the
    /// first words of the plain text, as many as the items have and three more.
    static func plainHasItems(_ plain: String, items: [String]) -> Bool {
        let units = soundUnits(plain)
        let head = Array(units.prefix(3 + items.reduce(0) { $0 + max(1, $1.split(separator: " ").count) }))
        var present = 0
        for item in items {
            let size = max(1, item.split(separator: " ").count)
            var found = false
            for start in head.indices {
                for length in max(1, size - 1)...(size + 1) where start + length <= head.count {
                    let piece = head[start..<(start + length)].joined(separator: " ")
                    if VocabularyEcho.normalized(piece) == VocabularyEcho.normalized(item) || soundsAlike(piece, item) {
                        found = true
                    }
                }
            }
            if found { present += 1 }
        }
        return present * 2 >= items.count
    }

    /// Latin words and Han runs of the text, in order. A Han run is cut into pieces of two
    /// characters, so it can be compared with a Chinese name.
    static func soundUnits(_ text: String) -> [String] {
        var units: [String] = []
        var latin = ""
        var han = ""
        func flush() {
            if !latin.isEmpty {
                units.append(latin)
                latin = ""
            }
            if !han.isEmpty {
                let characters = Array(han)
                var i = 0
                while i < characters.count {
                    units.append(String(characters[i..<min(i + 2, characters.count)]))
                    i += 2
                }
                han = ""
            }
        }
        for character in text {
            if character.isHan {
                if !latin.isEmpty { flush() }
                han.append(character)
            } else if character.isLetter || character.isNumber || character == "'" {
                if !han.isEmpty { flush() }
                latin.append(character)
            } else {
                flush()
            }
        }
        flush()
        return units
    }

    // MARK: Coverage

    /// The share of the text's words that lie inside terms, or inside the capitalized words
    /// of Latin terms. A list the model wrote out is close to 1, a dictation that names two
    /// people far below.
    static func termCoverage(_ text: String, terms: [String]) -> Double {
        let characters = Array(text)
        let units = unitStarts(characters)
        guard !units.isEmpty else { return 0 }
        let ranges = occurrences(of: expandedNames(terms), in: characters)
        let covered = units.filter { unit in ranges.contains { $0.contains(unit) } }.count
        return Double(covered) / Double(units.count)
    }

    /// The terms, and the capitalized words of three letters or more of each Latin term of
    /// several words, as Rosalie and Witch in Rosalie the Witch, never a title.
    static func expandedNames(_ terms: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ name: String) {
            guard name.count >= 2, seen.insert(name.lowercased()).inserted else { return }
            result.append(name)
        }
        for term in terms {
            add(term)
            let parts = term.split(separator: " ").map(String.init)
            if parts.count > 1, parts.allSatisfy({ $0.allSatisfy(\.isASCII) }) {
                for part in parts where part.count >= 3 && part.first?.isUppercase == true && !ScreenNames.isTitle(part) {
                    add(part)
                }
            }
        }
        return result
    }

    /// Where the names occur in the text, the longest first, never overlapping. Latin names
    /// only as whole words, ignoring case. Han names anywhere.
    static func occurrences(of names: [String], in text: [Character]) -> [Range<Int>] {
        let lower = text.map { Character($0.lowercased()) }
        var found: [Range<Int>] = []
        for name in names.sorted(by: { $0.count > $1.count }) {
            let needle = Array(name.lowercased())
            guard !needle.isEmpty, needle.count <= lower.count else { continue }
            let latinEnds = name.first?.isASCIILetterOrDigit == true
            for start in 0...(lower.count - needle.count) where Array(lower[start..<(start + needle.count)]) == needle {
                let range = start..<(start + needle.count)
                if latinEnds {
                    if start > 0, text[start - 1].isASCIILetterOrDigit { continue }
                    if range.upperBound < text.count, text[range.upperBound].isASCIILetterOrDigit { continue }
                }
                if found.contains(where: { $0.overlaps(range) }) { continue }
                found.append(range)
            }
        }
        return found
    }

    /// Where each word of the text starts: a Han character, or the first letter or digit of
    /// a Latin run.
    static func unitStarts(_ characters: [Character]) -> [Int] {
        characters.indices.filter { i in
            let character = characters[i]
            if character.isHan { return true }
            guard character.isLetter || character.isNumber else { return false }
            return i == 0 || !(characters[i - 1].isLetter || characters[i - 1].isNumber) || characters[i - 1].isHan
        }
    }

    /// How many words the text has, a Latin word or a Han character each.
    static func unitCount(_ text: String) -> Int {
        unitStarts(Array(text)).count
    }
}
