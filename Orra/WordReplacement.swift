import Foundation

/// A word Orra wrote in place of what the speech model wrote, in the text it pasted.
nonisolated struct Replacement: Equatable, Hashable, Sendable {
    /// Where Orra's word is in the text after the replacements, in characters.
    var span: Range<Int>
    /// What the model wrote there.
    var heard: String
    /// What Orra wrote instead.
    var corrected: String
    /// The kept pair that called for it.
    var pair: Correction
}

/// Puts the user's own words back into a transcript, after the rule steps and before the
/// cleanup model. Pure, so tests can feed it text.
///
/// The words come from the pairs the user taught Orra by fixing a misheard word, such as
/// 克劳德 to Claude, and kept, whose word is still in the vocabulary. Each place the model
/// wrote the heard spelling gets the user's word. The heard spelling is matched as learning
/// saw it, in the pasted text after the rule steps:
/// - Latin letters at word boundaries only, so a pair for Ora never touches Orange, and
///   exactly but for the case of the first letter, which a sentence start changes.
/// - Chinese characters as they are, but never inside a vocabulary word, never inside the
///   user's word of another pair, never cutting into a word as the system's word breaker
///   finds it, and never a heard spelling of one character.
/// - A heard spelling made only of ordinary words, such as there for their, a pie for API
///   or 生根 for 申根, is never replaced, since it is far more often meant as written.
/// - A heard spelling that is itself a vocabulary word, or that two pairs fix in different
///   ways, is left alone.
/// - The longest heard spelling wins where two overlap, and every replacement is made in
///   the transcript as the model wrote it, so one never feeds another.
///
/// Measured on 2026-10-12 on text only: the 93 pairs learning would keep from fixing 600
/// Qwen3-ASR 1.7B transcripts to their references, applied to 15,951 English and 17,809
/// Chinese texts that are correct, replaced nothing in English and one name's other
/// spelling (艾德 for 埃德) 9 times in Chinese. Without the ordinary word check they made
/// 3,589 false replacements in English. Near matches of vocabulary words, such as
/// Kubernetis for Kubernetes, were left out: the strictest rules tried still changed 513
/// correct words when every ContextASR term was in the vocabulary, such as Zhejiang to
/// Zhenjiang and prebiotic to probiotic, and fixed none of the stored transcripts' misses.
nonisolated enum WordReplacement {
    /// The transcript with the user's words, and where each replacement went.
    static func apply(
        to text: String,
        pairs: [Correction],
        vocabulary: [String],
        ordinary: OrdinaryWords
    ) -> (text: String, replacements: [Replacement]) {
        let characters = Array(text)
        guard !characters.isEmpty, !pairs.isEmpty, !vocabulary.isEmpty else { return (text, []) }
        let usable = usablePairs(pairs, vocabulary: vocabulary, ordinary: ordinary)
        guard !usable.isEmpty else { return (text, []) }
        let protected = vocabularyRanges(in: characters, vocabulary: vocabulary + pairs.map(\.corrected))
        return applying(pairEdits(in: characters, pairs: usable, protected: protected), to: characters)
    }

    // MARK: Learned pairs

    /// One change to make in the transcript, in its characters.
    struct Edit: Equatable, Sendable {
        var range: Range<Int>
        var corrected: String
        var pair: Correction
    }

    /// The pairs that may replace text: the user's word is in the vocabulary, and the heard
    /// spelling is longer than one character, no vocabulary word, not only ordinary English
    /// words, and fixed one way only.
    static func usablePairs(_ pairs: [Correction], vocabulary: [String], ordinary: OrdinaryWords) -> [Correction] {
        let words = Set(vocabulary.map { $0.lowercased() })
        let candidates = Set(pairs).filter { pair in
            pair.heard.count > 1 && pair.heard != pair.corrected
                && pair.heard.trimmingCharacters(in: .whitespacesAndNewlines) == pair.heard
                && !pair.heard.contains(where: \.isNewline)
                && words.contains(pair.corrected.lowercased())
                // A heard spelling that is a vocabulary word is the user's word too, unless
                // the pair only fixes its case, as kvlite to KVLite.
                && (!words.contains(pair.heard.lowercased()) || pair.heard.lowercased() == pair.corrected.lowercased())
                && !ordinary.holdsOnlyOrdinaryWords(pair.heard)
        }
        // Two pairs for the same heard spelling with different words: the user's fixes do
        // not agree, so neither is used.
        var corrections: [String: Set<String>] = [:]
        for pair in candidates {
            corrections[key(pair.heard), default: []].insert(pair.corrected)
        }
        return candidates.filter { corrections[key($0.heard)]?.count == 1 }
            .sorted { ($0.heard.count, $0.heard, $0.corrected) > ($1.heard.count, $1.heard, $1.corrected) }
    }

    /// A heard spelling with the case of its first letter set aside.
    private static func key(_ heard: String) -> String {
        guard let first = heard.first else { return heard }
        return first.lowercased() + heard.dropFirst()
    }

    /// Where the vocabulary words are in the transcript: Latin ends at word boundaries,
    /// ignoring case, as `Vocabulary.markingUsed` counts them.
    static func vocabularyRanges(in text: [Character], vocabulary: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let lowered = text.map { Character($0.lowercased()) }
        let present = Set(lowered)
        // Most words are ruled out by a set lookup: each of their characters must be there.
        for word in Set(vocabulary.map { Array($0.lowercased()) }) where !word.isEmpty && word.allSatisfy(present.contains) {
            ranges += occurrences(of: word, in: lowered, caseInsensitiveFirst: false)
        }
        return ranges
    }

    /// The pairs' heard spellings in the transcript, longest first and then the earliest,
    /// that overlap no vocabulary word and no other chosen replacement.
    private static func pairEdits(in text: [Character], pairs: [Correction], protected: [Range<Int>]) -> [Edit] {
        var found: [Edit] = []
        let present = Set(text.map { Character($0.lowercased()) })
        // A Chinese end of a heard spelling must be where the system's word breaker ends a
        // word, so a pair never cuts into a word, as 丹尼 into 丹尼尔.
        var boundaries: Set<Int>?
        for pair in pairs where pair.heard.lowercased().allSatisfy(present.contains) {
            for range in occurrences(of: Array(pair.heard), in: text, caseInsensitiveFirst: true)
            // The same range is the user's word in another case, which a pair that only
            // fixes the case replaces.
            where !protected.contains(where: { $0.overlaps(range) && $0 != range }) {
                if isHan(text[range.lowerBound]) || isHan(text[range.upperBound - 1]) {
                    let words = boundaries ?? ChineseWords.boundaries(in: String(text))
                    boundaries = words
                    if isHan(text[range.lowerBound]), !words.contains(range.lowerBound) { continue }
                    if isHan(text[range.upperBound - 1]), !words.contains(range.upperBound) { continue }
                }
                found.append(Edit(range: range, corrected: pair.corrected, pair: pair))
            }
        }
        found.sort { ($0.range.count, -$0.range.lowerBound) > ($1.range.count, -$1.range.lowerBound) }
        var chosen: [Edit] = []
        for edit in found where !chosen.contains(where: { $0.range.overlaps(edit.range) }) {
            chosen.append(edit)
        }
        return chosen
    }

    /// Every place the needle is in the text. A needle that starts or ends with a Latin
    /// letter or digit counts only where no Latin letter or digit is next to that end.
    /// With `caseInsensitiveFirst`, a first Latin letter may differ in case.
    static func occurrences(of needle: [Character], in text: [Character], caseInsensitiveFirst: Bool) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= text.count else { return [] }
        let checksStart = isLatinLetterOrDigit(needle[0])
        let checksEnd = isLatinLetterOrDigit(needle[needle.count - 1])
        var ranges: [Range<Int>] = []
        for start in 0...(text.count - needle.count) {
            guard needle.indices.allSatisfy({ index in
                let character = text[start + index]
                return character == needle[index]
                    || (index == 0 && caseInsensitiveFirst && needle[0].isASCII && needle[0].isLetter
                        && character.lowercased() == needle[0].lowercased())
            }) else { continue }
            let end = start + needle.count
            if checksStart, start > 0, isLatinLetterOrDigit(text[start - 1]) { continue }
            if checksEnd, end < text.count, isLatinLetterOrDigit(text[end]) { continue }
            ranges.append(start..<end)
        }
        return ranges
    }

    // MARK: Latin words

    /// A run of Latin letters and digits, with the marks that join a name inside it, as in
    /// GPT-4o or Node.js.
    struct LatinWord: Equatable, Sendable {
        var range: Range<Int>
        /// Lowercase letters and digits only.
        var normalized: String
        /// The parts between the joining marks, lowercased, for the ordinary word check.
        var parts: [String]
    }

    static func latinWords(in text: [Character]) -> [LatinWord] {
        var words: [LatinWord] = []
        var index = 0
        while index < text.count {
            guard isLatinLetterOrDigit(text[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < text.count, isLatinLetterOrDigit(text[index])
                    || (isJoiner(text[index]) && index + 1 < text.count && isLatinLetterOrDigit(text[index + 1])) {
                index += 1
            }
            let raw = String(text[start..<index]).lowercased()
            words.append(LatinWord(
                range: start..<index,
                normalized: String(raw.filter(isLatinLetterOrDigit)),
                parts: raw.split(whereSeparator: { !isLatinLetterOrDigit($0) }).map(String.init)
            ))
        }
        return words
    }

    // MARK: Applying

    /// The text with the edits made, and where each one went.
    static func applying(_ edits: [Edit], to text: [Character]) -> (text: String, replacements: [Replacement]) {
        guard !edits.isEmpty else { return (String(text), []) }
        var output: [Character] = []
        var replacements: [Replacement] = []
        var position = 0
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            output += text[position..<edit.range.lowerBound]
            let start = output.count
            output += Array(edit.corrected)
            replacements.append(Replacement(span: start..<output.count, heard: String(text[edit.range]), corrected: edit.corrected, pair: edit.pair))
            position = edit.range.upperBound
        }
        output += text[position...]
        return (String(output), replacements)
    }

    // MARK: Characters

    static func isLatinLetterOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    private static func isJoiner(_ character: Character) -> Bool {
        "-_.+'".contains(character)
    }
}

/// Ordinary English words, from the word lists every Mac has in /usr/share/dict: web2, the
/// words of Webster's Second International, and the common first names. Read once, off
/// the main actor, the first time a replacement asks.
nonisolated struct OrdinaryWords: Sendable {
    private let words: Set<String>
    private let everything: Bool

    /// The system's lists. Without them every word counts as ordinary, so nothing Latin is
    /// replaced.
    static let system: OrdinaryWords = {
        let files = ["/usr/share/dict/web2", "/usr/share/dict/propernames", "/usr/share/dict/connectives"]
        var words: [String] = []
        for path in files {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            words += text.split(whereSeparator: \.isNewline).map(String.init)
        }
        return OrdinaryWords(words, everything: words.isEmpty)
    }()

    init(_ words: some Sequence<String>, everything: Bool = false) {
        self.words = Set(words.map { $0.lowercased() })
        self.everything = everything
    }

    /// Whether the lowercased word, or the word without a common ending, is in the lists.
    /// Words of one or two letters always count, and so do numbers.
    func contains(_ word: String) -> Bool {
        let word = word.lowercased()
        if everything || word.count <= 2 || word.allSatisfy(\.isNumber) || words.contains(word) { return true }
        for (ending, replacement) in Self.endings where word.hasSuffix(ending) && word.count > ending.count + 2 {
            let stem = String(word.dropLast(ending.count)) + replacement
            if words.contains(stem) { return true }
            // running to run, stopped to stop.
            if replacement.isEmpty, let last = stem.last, stem.dropLast().last == last, words.contains(String(stem.dropLast())) {
                return true
            }
        }
        // Two words written as one, as in layup or livestream.
        let letters = Array(word)
        if letters.count >= 4 {
            for split in 2...(letters.count - 2) where words.contains(String(letters[..<split])) && contains(String(letters[split...])) {
                return true
            }
        }
        return false
    }

    private static let endings: [(String, String)] = [
        ("'s", ""), ("s", ""), ("es", ""), ("ies", "y"), ("ed", ""), ("ed", "e"), ("ied", "y"),
        ("ing", ""), ("ing", "e"), ("ly", ""), ("er", ""), ("er", "e"), ("est", ""), ("ers", ""),
        ("cking", "c"), ("cked", "c"),
    ]

    /// Whether a word, with its joined parts, is ordinary: every part is.
    func isOrdinary(_ word: WordReplacement.LatinWord) -> Bool {
        word.parts.allSatisfy(contains)
    }

    /// Whether the text is ordinary words only: Latin words that are all ordinary, as in
    /// there or a pie, or Chinese characters that are ordinary words, as in 生根 or 时候在,
    /// see `ChineseWords.isOrdinary(_:)`.
    func holdsOnlyOrdinaryWords(_ text: String) -> Bool {
        let characters = Array(text)
        if !characters.isEmpty, characters.allSatisfy(WordReplacement.isHan) {
            return ChineseWords.isOrdinary(text)
        }
        guard !characters.contains(where: { $0.isLetter && !WordReplacement.isLatinLetterOrDigit($0) }) else { return false }
        let words = WordReplacement.latinWords(in: characters)
        return !words.isEmpty && words.allSatisfy(isOrdinary)
    }
}

/// Chinese words as the system's word breaker finds them, with its lexicon of Simplified
/// Chinese.
nonisolated enum ChineseWords {
    /// The word boundaries in the text, as character offsets.
    static func boundaries(in text: String) -> Set<Int> {
        let string = text as NSString
        guard string.length > 0 else { return [0] }
        let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRangeMake(0, string.length),
            kCFStringTokenizerUnitWord, Locale(identifier: "zh-Hans") as CFLocale
        )
        // UTF-16 offsets to character offsets.
        var characterOffset: [Int: Int] = [:]
        var utf16 = 0
        for (index, character) in text.enumerated() {
            characterOffset[utf16] = index
            utf16 += character.utf16.count
        }
        characterOffset[utf16] = text.count
        var result: Set<Int> = [0, text.count]
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let start = characterOffset[range.location] { result.insert(start) }
            if let end = characterOffset[range.location + range.length] { result.insert(end) }
        }
        return result
    }

    /// Whether the word breaker splits the text into words of its lexicon only: words of
    /// two characters or more, and single characters that are grammar, such as 在 or 的,
    /// as in 生根 or 时候在. A misheard name leaves a single character that is no grammar:
    /// 克劳德 is broken into 克 and 劳德, 通一千问 into four characters.
    static func isOrdinary(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 2 else { return false }
        let cuts = boundaries(in: text).sorted()
        return zip(cuts, cuts.dropFirst()).allSatisfy { start, end in
            end - start >= 2 || OneCharacterFix.functionWords.contains(characters[start])
        }
    }
}
