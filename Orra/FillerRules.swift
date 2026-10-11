import Foundation

/// Removes filler words that never carry meaning from a transcript, such as 呃 and um.
///
/// Qwen3-ASR writes nearly every hesitation it hears. These rules remove only the fillers
/// that are empty wherever they stand, and leave everything that might mean something to
/// the text as dictated:
/// - 呃 everywhere, except in the word 呃逆.
/// - 额 standing alone, not next to another Chinese character, so 金额, 额度 and names stay.
/// - 嗯, unless it is the whole dictation, ends a clause or sentence as an answer (我说嗯。),
///   or comes before a reply such as 嗯，好的, 嗯对 or 嗯，是的.
/// - um, umm, uh, uhh, uhm and erm as whole words in any case, except in capitals, which is
///   an acronym such as UM, and in replies such as uh-huh, uh huh and uh oh.
/// - 啊 and 哦 only at the start of a clause and before a comma, as in 啊，我忘了, and not
///   before a correction such as 哦，不是四点, where they carry the change of mind.
///
/// A filler in quotation marks is quoted, not spoken, and stays. Um and Uh after a title
/// such as Dr. are surnames.
///
/// 吧, 呢, 嘛, 呀, a 啊 at the end of a sentence, 那个, 这个, like and repeated words such as
/// 看看 are never touched, because they often mean something. A filler before a question
/// mark stays too (嗯？). The comma or space a filler leaves behind goes with it, and an
/// English sentence that began with a capitalized filler begins with a capital again.
/// When nothing would be left, the dictation stays as it was.
nonisolated enum FillerRules {
    private static let commas: Set<Character> = ["，", ",", "、"]
    private static let sentenceEnds: Set<Character> = ["。", ".", "！", "!", "？", "?"]
    private static let questionMarks: Set<Character> = ["？", "?"]
    private static let clauseEnds: Set<Character> = commas.union(sentenceEnds).union(["；", ";", "：", ":"])
    private static let englishFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm"]
    /// Words after uh or um that make it a reply or an interjection.
    private static let replyWords: Set<String> = ["huh", "oh", "hm", "hmm"]
    /// Replies after 嗯 that keep it, as whole words before punctuation or the end.
    private static let replies = ["是这样", "对的", "对对", "好的", "好吧", "是的", "没错", "可以", "对", "好", "行", "是"]
    /// The first characters of a clause that corrects the one before.
    private static let correctionStarts: Set<Character> = ["不", "没", "错", "别"]
    private static let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "「", "」", "『", "』"]
    private static let titles = ["Mr.", "Mrs.", "Ms.", "Mx.", "Dr.", "Prof."]
    private static let ellipsis: Set<Character> = [".", "…"]

    /// A filler found in the text: where it starts and ends, and whether it is an English
    /// word written with a capital.
    private struct Filler {
        var start: Int
        var end: Int
        var isCapitalizedWord: Bool
    }

    static func removingFillers(from text: String) -> String {
        var characters = Array(text)
        var output: [Character] = []
        var removedAny = false
        var index = 0
        while index < characters.count {
            guard let filler = filler(at: index, in: characters, after: output) else {
                output.append(characters[index])
                index += 1
                continue
            }
            removedAny = true
            index = remove(filler, from: &characters, into: &output)
        }
        guard removedAny else { return text }
        let result = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        return result
    }

    private static func filler(at index: Int, in characters: [Character], after output: [Character]) -> Filler? {
        guard let found = unquotedFiller(at: index, in: characters, after: output) else { return nil }
        if found.start > 0, quotes.contains(characters[found.start - 1]) { return nil }
        if found.end < characters.count, quotes.contains(characters[found.end]) { return nil }
        return found
    }

    private static func unquotedFiller(at index: Int, in characters: [Character], after output: [Character]) -> Filler? {
        let character = characters[index]
        switch character {
        case "呃":
            let end = runEnd(of: character, from: index, in: characters)
            guard end >= characters.count || characters[end] != "逆" else { return nil }
            return chineseFiller(index, end, characters)
        case "额":
            let end = runEnd(of: character, from: index, in: characters)
            if index > 0, isHan(characters[index - 1]) { return nil }
            if end < characters.count, isHan(characters[end]) { return nil }
            return chineseFiller(index, end, characters)
        case "嗯":
            let end = runEnd(of: character, from: index, in: characters)
            // An answer: 嗯 at the end of a clause, a sentence or the dictation.
            let after = skippingSpaces(from: end, in: characters)
            if after >= characters.count || sentenceEnds.contains(characters[after]) { return nil }
            var next = after
            while next < characters.count, characters[next].isWhitespace || commas.contains(characters[next]) {
                next += 1
            }
            if startsReply(at: next, in: characters) { return nil }
            return chineseFiller(index, end, characters)
        case "啊", "哦":
            guard startsClause(output) else { return nil }
            let end = runEnd(of: character, from: index, in: characters)
            let next = skippingSpaces(from: end, in: characters)
            guard next < characters.count, commas.contains(characters[next]) else { return nil }
            let clause = skippingSpaces(from: next + 1, in: characters)
            if clause < characters.count, correctionStarts.contains(characters[clause]) { return nil }
            return Filler(start: index, end: end, isCapitalizedWord: false)
        default:
            return englishFiller(at: index, in: characters)
        }
    }

    private static func chineseFiller(_ start: Int, _ end: Int, _ characters: [Character]) -> Filler? {
        let next = skippingSpaces(from: end, in: characters)
        if next < characters.count, questionMarks.contains(characters[next]) { return nil }
        return Filler(start: start, end: end, isCapitalizedWord: false)
    }

    private static func englishFiller(at index: Int, in characters: [Character]) -> Filler? {
        guard isASCIILetter(characters[index]) else { return nil }
        if index > 0, isWordPart(characters[index - 1]) { return nil }
        var end = index
        while end < characters.count, isASCIILetter(characters[end]) {
            end += 1
        }
        if end < characters.count, isWordPart(characters[end]) { return nil }
        let word = String(characters[index..<end])
        guard englishFillers.contains(word.lowercased()) else { return nil }
        // UM or UH in capitals is an acronym, such as a university.
        if word == word.uppercased() { return nil }
        // Dr. Um is a person.
        if characters[index].isUppercase {
            let before = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
            if titles.contains(where: { before.hasSuffix($0) }) { return nil }
        }
        let next = skippingSpaces(from: end, in: characters)
        if next < characters.count, questionMarks.contains(characters[next]) { return nil }
        if next > end {
            var wordEnd = next
            while wordEnd < characters.count, isASCIILetter(characters[wordEnd]) {
                wordEnd += 1
            }
            if replyWords.contains(String(characters[next..<wordEnd]).lowercased()) { return nil }
        }
        return Filler(start: index, end: end, isCapitalizedWord: characters[index].isUppercase)
    }

    /// Leaves out the filler with the comma after it, mends the spacing and punctuation
    /// where it was, and returns the index to go on from.
    private static func remove(_ filler: Filler, from characters: inout [Character], into output: inout [Character]) -> Int {
        var hadSpace = false
        while let last = output.last, last.isWhitespace {
            output.removeLast()
            hadSpace = true
        }
        let atSentenceStart = output.last.map { sentenceEnds.contains($0) } ?? true
        var index = skippingSpaces(from: filler.end, in: characters)
        hadSpace = hadSpace || index > filler.end
        // An ellipsis after the filler belongs to it: "Um... I think" or "呃……我想".
        var ellipsisEnd = index
        while ellipsisEnd < characters.count, ellipsis.contains(characters[ellipsisEnd]) {
            ellipsisEnd += 1
        }
        if ellipsisEnd - index > 1 || (ellipsisEnd > index && characters[index] == "…") {
            let afterEllipsis = skippingSpaces(from: ellipsisEnd, in: characters)
            hadSpace = hadSpace || afterEllipsis > ellipsisEnd
            index = afterEllipsis
        } else if index < characters.count {
            let next = characters[index]
            // The comma that belongs to the filler, or the full stop of a filler that was a
            // sentence of its own, such as "Um. Let me think."
            if commas.contains(next) || (atSentenceStart && sentenceEnds.contains(next) && !questionMarks.contains(next)) {
                let afterPunctuation = skippingSpaces(from: index + 1, in: characters)
                hadSpace = hadSpace || afterPunctuation > index + 1
                index = afterPunctuation
            }
        }

        if output.isEmpty {
            while index < characters.count, commas.contains(characters[index]) || characters[index].isWhitespace {
                index += 1
            }
        } else if let last = output.last {
            if index >= characters.count {
                if commas.contains(last) {
                    output.removeLast()
                }
            } else if commas.contains(last), sentenceEnds.contains(characters[index]) {
                output.removeLast()
            } else if commas.contains(last) || sentenceEnds.contains(last), commas.contains(characters[index]) {
                index = skippingSpaces(from: index + 1, in: characters)
            }
        }

        if hadSpace, let last = output.last, index < characters.count, needsSpace(between: last, and: characters[index]) {
            output.append(" ")
        }
        if filler.isCapitalizedWord, atSentenceStart {
            capitalizeWord(at: index, in: &characters)
        }
        return index
    }

    /// Capitalizes a word written all in lowercase, so "iPhone" stays as it is.
    private static func capitalizeWord(at index: Int, in characters: inout [Character]) {
        guard index < characters.count, characters[index].isLowercase, isASCIILetter(characters[index]) else { return }
        var end = index + 1
        while end < characters.count, characters[end].isLetter {
            if characters[end].isUppercase { return }
            end += 1
        }
        characters[index] = Character(characters[index].uppercased())
    }

    /// Whether a space goes where a filler was, given that there was one: between English
    /// words, after English punctuation, and between Chinese and English, the way the
    /// speech model writes it. Never next to Chinese punctuation or before punctuation.
    private static func needsSpace(between last: Character, and next: Character) -> Bool {
        if isPunctuation(next) { return false }
        if last.isASCII, isPunctuation(last) { return true }
        if isPunctuation(last) { return false }
        return isLatinOrDigit(last) || isLatinOrDigit(next)
    }

    private static func runEnd(of character: Character, from index: Int, in characters: [Character]) -> Int {
        var end = index
        while end < characters.count, characters[end] == character {
            end += 1
        }
        return end
    }

    private static func skippingSpaces(from index: Int, in characters: [Character]) -> Int {
        var next = index
        while next < characters.count, characters[next].isWhitespace {
            next += 1
        }
        return next
    }

    /// True at the start of the text or right after a comma or the end of a sentence.
    private static func startsClause(_ output: [Character]) -> Bool {
        guard let last = output.last(where: { !$0.isWhitespace }) else { return true }
        return clauseEnds.contains(last)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    /// Latin letters, digits, hyphens and apostrophes join a word, so um in "umbrella",
    /// "uh-huh" and "um's" is not a filler. A Chinese character does not, so uh in 我uh觉得 is.
    private static func isWordPart(_ character: Character) -> Bool {
        isLatinOrDigit(character) || character == "-" || character == "'" || character == "’"
    }

    /// Whether a reply such as 好的 starts here and stands as a word of its own.
    private static func startsReply(at index: Int, in characters: [Character]) -> Bool {
        for reply in replies {
            let word = Array(reply)
            let end = index + word.count
            guard end <= characters.count, Array(characters[index..<end]) == word else { continue }
            if end == characters.count || isPunctuation(characters[end]) || characters[end].isWhitespace {
                return true
            }
        }
        return false
    }

    private static func isLatinOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.isPunctuation
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF:
                true
            default:
                false
            }
        }
    }
}

/// Whether Orra removes fillers. On until the user turns it off in Settings.
nonisolated enum FillerPreference {
    static let defaultsKey = "removesFillerWords"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func save(_ on: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: defaultsKey)
    }
}
