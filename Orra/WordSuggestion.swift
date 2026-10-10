import Foundation
import NaturalLanguage

/// A word Orra offers to add after the user changed one Chinese character, such as 通一千问
/// to 通义千问. One character is too little to learn on its own, so the user decides, and
/// may edit the guess first.
nonisolated struct WordSuggestion: Equatable, Hashable, Sendable {
    /// The changed character as heard and as corrected: 一 and 义.
    var change: Correction
    /// The guessed word as heard and as corrected: 通一千问 and 通义千问.
    var pair: Correction

    var guess: String { pair.corrected }

    /// The pair to keep for the word the user added, which may differ from the guess. The
    /// heard spelling is the word with the changed character as it was heard.
    func pair(for word: String) -> Correction {
        if word == pair.corrected { return pair }
        if word.contains(pair.corrected) {
            return Correction(heard: word.replacingOccurrences(of: pair.corrected, with: pair.heard), corrected: word)
        }
        if let range = word.range(of: change.corrected) {
            return Correction(heard: word.replacingCharacters(in: range, with: change.heard), corrected: word)
        }
        return Correction(heard: pair.heard, corrected: word)
    }
}

/// Finds a fix of exactly one Chinese character that may be part of a name, and guesses
/// the whole word. Pure, so tests can feed it text.
nonisolated enum OneCharacterFix {
    /// The longest guess, in characters.
    static let maximumGuessLength = 6

    /// Characters that sound alike and are swapped as grammar or as common typos, never as
    /// part of a misheard name. A fix between two characters of the same group is never
    /// offered. Each pair has the same pinyin without tones (地 is also read de), so the
    /// sound rule alone would let them through.
    static let grammarGroups: [Set<Character>] = [
        ["的", "地", "得"],
        ["在", "再"],
        ["做", "作"],
        ["他", "她", "它"],
        ["那", "哪"],
        ["象", "像"],
        ["已", "以"],
        ["帐", "账"],
        ["坐", "座"],
        ["带", "戴"],
        ["须", "需"],
        ["即", "既"],
        ["份", "分"],
        ["进", "近"],
        ["和", "合"],
    ]

    /// Single character words that end a guess: pronouns, particles, common verbs and
    /// prepositions, which sit next to a name rather than inside it.
    static let functionWords: Set<Character> = Set("我你他她它的了是在和跟与用把被给叫说写去来到也都就还又很这那吗呢吧啊个一不没有让对从向为及")

    static func isGrammar(_ first: Character, _ second: Character) -> Bool {
        grammarGroups.contains { $0.contains(first) && $0.contains(second) }
    }

    /// The suggestion for a paste that the user changed into `edited`, when exactly one Han
    /// character was replaced by another that sounds alike and the two are not grammar.
    static func suggestion(pasted: String, edited editedText: String) -> WordSuggestion? {
        let paste = Array(pasted)
        var edited = Array(editedText)
        // Punctuation or spaces typed right after the paste, such as a closing period.
        while edited.count > paste.count, let last = edited.last, isSeparator(last) {
            edited.removeLast()
        }
        guard paste.count == edited.count, paste != edited else { return nil }
        let changed = paste.indices.filter { paste[$0] != edited[$0] }
        guard changed.count == 1, let index = changed.first else { return nil }
        let heard = paste[index]
        let corrected = edited[index]
        guard isHan(heard), isHan(corrected), !isGrammar(heard, corrected),
              SoundAlike.sound(String(heard)) == SoundAlike.sound(String(corrected))
                || SoundAlike.soundsAlike(String(heard), String(corrected)) else { return nil }
        let range = guess(in: edited, at: index)
        return WordSuggestion(
            change: Correction(heard: String(heard), corrected: String(corrected)),
            pair: Correction(heard: String(paste[range]), corrected: String(edited[range]))
        )
    }

    /// The span of the word around the character at `index`: the system tokenizer's word
    /// when it put the character in one, or else the character with the Han characters
    /// around it that the tokenizer left alone, since it splits an unknown name into single
    /// characters. Stops at punctuation, other scripts, a longer word and the function
    /// words, and at `maximumGuessLength`.
    static func guess(in text: [Character], at index: Int) -> Range<Int> {
        let split = tokens(in: text)
        if let token = split.word(at: index) {
            return token.count <= maximumGuessLength ? token : index..<(index + 1)
        }
        func joins(_ position: Int) -> Bool {
            text.indices.contains(position) && isHan(text[position]) && split.isSingle(position)
                && !functionWords.contains(text[position])
        }
        var lower = index
        var upper = index + 1
        var growing = true
        while growing, upper - lower < maximumGuessLength {
            growing = false
            if joins(lower - 1) {
                lower -= 1
                growing = true
            }
            if upper - lower < maximumGuessLength, joins(upper) {
                upper += 1
                growing = true
            }
        }
        return lower..<upper
    }

    private struct Tokens {
        /// The token each character is in, by character offset. Nil for characters outside
        /// any token, such as punctuation and spaces.
        var ranges: [Range<Int>?]

        func isSingle(_ position: Int) -> Bool {
            ranges[position]?.count == 1
        }

        /// The word of two or more characters that holds `position`.
        func word(at position: Int) -> Range<Int>? {
            guard let range = ranges[position], range.count > 1 else { return nil }
            return range
        }
    }

    private static func tokens(in text: [Character]) -> Tokens {
        let string = String(text)
        var ranges = [Range<Int>?](repeating: nil, count: text.count)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = string
        tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
            let lower = string.distance(from: string.startIndex, to: range.lowerBound)
            let upper = string.distance(from: string.startIndex, to: range.upperBound)
            for position in lower..<upper where position < ranges.count {
                ranges[position] = lower..<upper
            }
            return true
        }
        return Tokens(ranges: ranges)
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || character.isSymbol
    }
}
