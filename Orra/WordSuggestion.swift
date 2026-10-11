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
    /// offered. Most pairs have the same pinyin without tones (地 is also read de), so the
    /// sound rule alone would let them through. The particles are listed whatever they
    /// sound like.
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
        // Sentence final particles, swapped as tone rather than misheard.
        ["吗", "嘛", "么"],
        ["呢", "哪"],
        ["吧", "啊"],
        ["了", "啦"],
    ]

    /// Single character words that end a guess: pronouns, particles, common verbs and
    /// prepositions, which sit next to a name rather than inside it. The verbs keep the
    /// guess, and the pair kept for it, from taking in the user's words around a name, as
    /// in 找王一博签名. The system's word classes cannot do this, since it tags the
    /// characters of an unknown name as verbs too.
    static let functionWords: Set<Character> = Set(
        "我你他她它的了是在和跟与用把被给叫说写去来到也都就还又很这那吗呢吧啊个一不没有让对从向为及"
            + "找发买卖看打请帮拿送听想要等吃喝查约见陪教回"
    )

    static func isGrammar(_ first: Character, _ second: Character) -> Bool {
        grammarGroups.contains { $0.contains(first) && $0.contains(second) }
    }

    /// The suggestion for a fix of the one Han character at `oldIndex` in the pasted text,
    /// `newIndex` in the edited text, when the two sound alike and are not grammar. The
    /// guessed word stays within `bounds` of the edited text, the unchanged text around the
    /// fix, so it never takes in another edit.
    static func suggestion(paste: [Character], edited: [Character], at oldIndex: Int, _ newIndex: Int, within bounds: Range<Int>) -> WordSuggestion? {
        let heard = paste[oldIndex]
        let corrected = edited[newIndex]
        guard isHan(heard), isHan(corrected), !isGrammar(heard, corrected),
              SoundAlike.sound(String(heard)) == SoundAlike.sound(String(corrected))
                || SoundAlike.soundsAlike(String(heard), String(corrected)) else { return nil }
        let range = guess(in: edited, at: newIndex, within: bounds)
        let shift = oldIndex - newIndex
        return WordSuggestion(
            change: Correction(heard: String(heard), corrected: String(corrected)),
            pair: Correction(heard: String(paste[(range.lowerBound + shift)..<(range.upperBound + shift)]), corrected: String(edited[range]))
        )
    }

    /// The span of the word around the character at `index`: the system tokenizer's word
    /// when it put the character in one, or else the character with the Han characters
    /// around it that the tokenizer left alone, since it splits an unknown name into single
    /// characters. Stops at punctuation, other scripts, a longer word and the function
    /// words, and at `maximumGuessLength`. So a name with a function word in it, or next to
    /// a word the tokenizer knows, is guessed in part: 文心一言 gives 言, and 欧阳娜娜 gives
    /// 娜娜. The user may edit the guess before adding it.
    static func guess(in text: [Character], at index: Int, within bounds: Range<Int>? = nil) -> Range<Int> {
        let bounds = bounds ?? text.indices
        let split = tokens(in: text)
        if let token = split.word(at: index) {
            let fits = token.count <= maximumGuessLength && bounds.lowerBound <= token.lowerBound && token.upperBound <= bounds.upperBound
            return fits ? token : index..<(index + 1)
        }
        return grow(index..<(index + 1), in: text, split, within: bounds, takingItsTokens: false)
    }

    /// An edit of two or more Han characters, such as 一千万 to 义千问 in 通义千问, widened
    /// the same way to the single characters around it that are not function words, and to
    /// the rest of a word the tokenizer found across its edge. Stays within `bounds` and
    /// grows to no more than `maximumGuessLength`, so 迪力热吧 to 迪丽热巴 gives 迪丽热巴.
    static func widen(_ range: Range<Int>, in text: [Character], within bounds: Range<Int>) -> Range<Int> {
        grow(range, in: text, tokens(in: text), within: bounds, takingItsTokens: true)
    }

    private static func grow(_ range: Range<Int>, in text: [Character], _ split: Tokens, within bounds: Range<Int>, takingItsTokens: Bool) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        func joins(_ position: Int) -> Bool {
            guard bounds.contains(position), isHan(text[position]), !functionWords.contains(text[position]) else { return false }
            if split.isSingle(position) { return true }
            guard takingItsTokens, let token = split.ranges[position] else { return false }
            return token.overlaps(lower..<upper)
        }
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
