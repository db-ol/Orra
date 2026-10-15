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
/// Chinese numerals. The length check holds a number to its length.
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

    /// Whether `heard` is close enough to `text`. Text with nothing to compare passes.
    static func passes(text: String, heard: String) -> Bool {
        let errors = wrongUnits(text: text, heard: heard)
        return errors.wrong < leastWrongUnits || Double(errors.wrong) <= mostWrongShare * Double(errors.length)
    }

    /// The edits that turn the units of `text` into those of `heard`, and how many units
    /// `text` has.
    static func wrongUnits(text: String, heard: String) -> (wrong: Int, length: Int) {
        let characters = usesCharacters(text)
        let expected = units(of: text, characters: characters)
        guard !expected.isEmpty else { return (0, 0) }
        return (editDistance(expected, units(of: heard, characters: characters)), expected.count)
    }

    /// Whether `text` is compared character by character: when it has any Chinese,
    /// Japanese or Korean character.
    static func usesCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCharacterScript)
    }

    /// The units of `text`, lowercased: each Chinese, Japanese or Korean character, and
    /// each word of letters. Digits and number words are left out. "okay" counts as "ok",
    /// and single letters in a row as one word, so "O.K." and "A P I" match "OK" and
    /// "API". With `characters`, words of letters are split into their letters, as Qwen3-ASR
    /// may write a Chinese word it misheard in letters.
    static func units(of text: String, characters: Bool) -> [String] {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        func endWord() {
            defer { word = String.UnicodeScalarView() }
            guard !word.isEmpty else { return }
            let text = String(word)
            guard !numberWords.contains(text) else { return }
            words.append(text == "okay" ? "ok" : text)
        }
        for scalar in text.lowercased().unicodeScalars {
            if isCharacterScript(scalar) {
                endWord()
                if !chineseNumerals.contains(scalar) {
                    words.append(String(scalar))
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                // A number is left out, and a word with digits in it, such as "v2", keeps
                // its letters.
                continue
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.append(scalar)
            } else if scalar == "'" || scalar == "’" {
                // It's, don't: one word.
                continue
            } else {
                endWord()
            }
        }
        endWord()
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

    /// English number words, which a number may be read as.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion",
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
