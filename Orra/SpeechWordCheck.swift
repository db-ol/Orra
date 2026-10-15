import Foundation

/// The word check of a sentence the voice model made, after SpeechCheck found its length
/// plausible: the speech model writes down what the audio says, and the piece fails when
/// too much of its text is not in it. SpeechCheck reads only the audio's length and level,
/// so it misses a voice that says other words in the right time, such as an English voice
/// that makes "Watony." of "我同意。".
///
/// Chinese, Japanese and Korean text is compared character by character, other text word
/// by word. Case and punctuation do not count. Numbers do not count either, on both sides,
/// because a number can be read in many ways ("5551234567" as "five five five" or "fifty
/// five fifty one"), and the speech model may write any of them in digits, English words or
/// Chinese numerals. The words that go with a number do not count with it, such as
/// "percent", 百分之 or 点半, since "10%" may be heard as "百分之十" and "2:30" as
/// "两点半". The length check holds a number to its length. In a review run on
/// 2026-10-15 (256 tries of contractions, percentages, fractions and times), counting those
/// words failed 80 tries that pass now, nearly all of them right, such as
/// "收入增长了百分之十。" and "We are ready.". The few others only read the number wrong.
///
/// The limits come from a scratch benchmark on 2026-10-14 and 2026-10-15: 1,546 clips of
/// Orra's two voice models that passed SpeechCheck, from four public voices, with what
/// Qwen3-ASR heard in them, and a new run of 464 clips (232 per model) and 216 short replies
/// and numbers. Good clips had at most a quarter of their text wrong. Every clip with more
/// than 0.3 of its text and at least two units wrong said other words, left words out or
/// spoke another language, judged by reading what was heard. On the new run the check
/// failed 3 of 323 tries of meeting sentences and 19 of 155 tries of short replies, most of
/// them short Chinese said by an English voice. The speech model took 0.15 s per piece at
/// the median and 0.26 s at most, against about 1.1 s to make the piece.
///
/// The speech model is told the language the voice model was asked to speak. Without it,
/// short Chinese in an English voice was often written as English words. In an end to end
/// run on 2026-10-15 (74 English to Chinese translations per voice model, every try heard
/// both ways), the hint cut the wrong share of checked tries from 0.30 and 0.65 to 0.20 and
/// 0.35 with Qwen3-TTS (two clip sets), and from 0.16 and 0.40 to 0.08 and 0.14 with
/// CosyVoice3, at the same time per piece. Fewer tries failed (63 to 56 of 221), and
/// translations that played nothing went from 9 to 8 and from 6 to 5. Chinese to English
/// did not change.
nonisolated enum SpeechWordCheck {
    /// A piece fails with more than this share of the units of its text wrong, when at
    /// least `leastWrongUnits` are wrong.
    static let mostWrongShare = 0.3
    /// One wrong unit never fails a piece, so "好的。" heard as "好。" passes.
    static let leastWrongUnits = 2

    /// The words and characters of `text` the check compares, see `units(of:characters:)`.
    /// Empty for text with nothing to compare, such as a number alone.
    static func units(of text: String) -> [String] {
        units(of: text, characters: usesCharacters(text))
    }

    /// When both tries of a piece fail only this check, the one with fewer wrong units
    /// plays, unless more than this share of its units is wrong, since then most of what
    /// the listener hears would be other words or another language. In the end to end run
    /// of 2026-10-15 (see above), 20 pieces failed both tries. The closer try had 0.38 to
    /// 0.46 of its units wrong in 4 of them and 0.57 to 1.4 in the other 16, and the limit
    /// sits in that gap. Playing the 4 cut the translations that played nothing from 8 to 6
    /// with Qwen3-TTS and from 5 to 4 with CosyVoice3, with no added wait.
    static let mostWrongShareToPlay = 0.5

    /// The wrong units of what was heard against the units of the text.
    struct Errors: Equatable, Sendable {
        var wrong: Int
        var length: Int

        /// The share of the text's units that is wrong, 0 for text with nothing to compare.
        var share: Double {
            length == 0 ? 0 : Double(wrong) / Double(length)
        }

        /// Whether what was heard is close enough to the text.
        var passes: Bool {
            wrong < SpeechWordCheck.leastWrongUnits || Double(wrong) <= SpeechWordCheck.mostWrongShare * Double(length)
        }
    }

    /// Whether `heard` is close enough to `text`. Text with nothing to compare passes.
    static func passes(text: String, heard: String) -> Bool {
        errors(text: text, heard: heard).passes
    }

    /// How far `heard` is from `text`.
    static func errors(text: String, heard: String) -> Errors {
        let errors = wrongUnits(text: text, heard: heard)
        return Errors(wrong: errors.wrong, length: errors.length)
    }

    /// The edits that turn the units of `text` into those of `heard`, and how many units
    /// `text` has.
    static func wrongUnits(text: String, heard: String) -> (wrong: Int, length: Int) {
        let characters = usesCharacters(text)
        let expected = units(of: text, characters: characters)
        guard !expected.isEmpty else { return (0, 0) }
        return (editDistance(expected, units(of: heard, characters: characters)), expected.count)
    }

    /// The language the speech model is told to write for a piece in `language`, nil for
    /// no hint. An English piece that keeps Chinese, Japanese or Korean characters, such as
    /// a name or a term, gets no hint: it is compared by character, and told to write
    /// English, the speech model would likely write those characters in pinyin or English
    /// words. Without a hint it listens as it did before the hint, which the limits were
    /// measured with. A Chinese piece keeps its hint.
    static func hint(for piece: String, in language: TranslationTarget) -> TranslationTarget? {
        language == .english && usesCharacters(piece) ? nil : language
    }

    /// Whether `text` is compared character by character: when it has any Chinese,
    /// Japanese or Korean character.
    static func usesCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCharacterScript)
    }

    /// The units of `text`, lowercased: each Chinese, Japanese or Korean character, and
    /// each word of letters. Traditional Chinese characters count as their simplified
    /// forms (ChineseText), since the speech model may write either. English contractions
    /// count as their long forms, so "I'm" matches "I am". Digits and number words are left
    /// out, and so are the words that go with a number, see `numberParts`. "okay" counts
    /// as "ok", and single letters in a row as one word, so "O.K." and "A P I" match "OK"
    /// and "API". With `characters`, words of letters are split into their letters, as
    /// Qwen3-ASR may write a Chinese word it misheard in letters.
    static func units(of text: String, characters: Bool) -> [String] {
        var words: [String] = []
        for token in numberParts(of: tokens(of: expandingContractions(ChineseText.simplifiedCharacters(text).lowercased()))) {
            if case .word(let word) = token {
                words.append(word == "okay" ? "ok" : word)
            }
        }
        var joined: [String] = []
        var letters = ""
        for word in words {
            if word.count == 1, !word.unicodeScalars.contains(where: isCharacterScript) {
                letters += word
                continue
            }
            if !letters.isEmpty {
                joined.append(letters)
                letters = ""
            }
            joined.append(word)
        }
        if !letters.isEmpty {
            joined.append(letters)
        }
        guard characters else { return joined }
        return joined.flatMap { word in
            word.unicodeScalars.contains(where: isCharacterScript) ? [word] : word.map(String.init)
        }
    }

    /// A word, a character or a number of a text.
    enum Token: Equatable {
        case word(String)
        case number
    }

    /// The words, characters and numbers of lowercased `text`. A word with digits in it,
    /// such as "v2", keeps its letters, and one that is a number with an ordinal ending,
    /// such as "1st", is a number.
    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var word = String.UnicodeScalarView()
        var hasDigits = false
        func endWord() {
            defer {
                word = String.UnicodeScalarView()
                hasDigits = false
            }
            let text = String(word)
            if numberWords.contains(text) || (hasDigits && (text.isEmpty || ordinalEndings.contains(text))) {
                tokens.append(.number)
            } else if !text.isEmpty {
                tokens.append(.word(text))
            }
        }
        for scalar in text.unicodeScalars {
            if isCharacterScript(scalar) {
                endWord()
                tokens.append(chineseNumerals.contains(scalar) ? .number : .word(String(scalar)))
            } else if CharacterSet.decimalDigits.contains(scalar) {
                hasDigits = true
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.append(scalar)
            } else if scalar == "'" {
                // Possessives and the contractions left: one word.
                continue
            } else {
                endWord()
            }
        }
        endWord()
        return tokens
    }

    /// `tokens` without the words that go with a number, which one side may write and the
    /// other not: "percent", "dollars" and "o'clock" after a number, "point" and "and"
    /// between numbers, "half past" and "quarter to" before one, and 点, 分, 之, 半 and 刻
    /// after a Chinese number, so "10%" matches "百分之十" and "2:30" matches "两点半" and
    /// "half past two".
    static func numberParts(of tokens: [Token]) -> [Token] {
        var kept: [Token] = []
        var afterNumber = false
        var index = 0
        func isNumber(_ at: Int) -> Bool {
            at < tokens.count && tokens[at] == .number
        }
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard case .word(let word) = token else {
                kept.append(token)
                afterNumber = true
                continue
            }
            if afterNumber, wordsAfterNumbers.contains(word) || (isNumber(index) && wordsBetweenNumbers.contains(word)) {
                continue
            }
            if ["half", "quarter"].contains(word), index < tokens.count, [.word("past"), .word("to")].contains(tokens[index]), isNumber(index + 1) {
                index += 1
                continue
            }
            kept.append(token)
            afterNumber = false
        }
        return kept
    }

    /// Lowercased `text` with English contractions in their long forms, and curly
    /// apostrophes straight.
    static func expandingContractions(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\u{2019}", with: "'")
        for (pattern, replacement) in contractions {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// Contractions and their long forms, in order. "'s" only after words where it can
    /// only mean "is", and "'d" not at all, since it may mean "had" or "would".
    static let contractions: [(String, String)] = [
        ("\\bwon't\\b", "will not"),
        ("\\bcan't\\b", "can not"),
        ("\\bcannot\\b", "can not"),
        ("\\bshan't\\b", "shall not"),
        ("n't\\b", " not"),
        ("'m\\b", " am"),
        ("'re\\b", " are"),
        ("'ve\\b", " have"),
        ("'ll\\b", " will"),
        ("\\blet's\\b", "let us"),
        ("\\b(it|that|what|there|here|he|she|who|where|how)'s\\b", "$1 is"),
    ]

    /// Ordinal endings of a number written in digits, such as "1st".
    static let ordinalEndings: Set<String> = ["st", "nd", "rd", "th"]

    /// Words that go with the number before them, see `numberParts`.
    static let wordsAfterNumbers: Set<String> = ["percent", "dollar", "dollars", "oclock", "点", "分", "之", "半", "刻"]

    /// Words that go between two numbers, see `numberParts`.
    static let wordsBetweenNumbers: Set<String> = ["point", "and"]

    /// English number words, which a number may be read as.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
    ]

    /// Chinese numerals, which a number may be read as. 幺 is one in a phone number.
    static let chineseNumerals: Set<Unicode.Scalar> = Set("零〇一二两三四五六七八九十百千万亿幺".unicodeScalars)

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func isCharacterScript(_ scalar: Unicode.Scalar) -> Bool {
        SpeechCheck.isCharacterScript(scalar)
    }
}
