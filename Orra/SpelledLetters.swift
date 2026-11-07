import Foundation

/// Joins capitals that the speech model wrote one by one in Chinese text, such as P R for
/// PR and O.K. for OK.
///
/// Qwen3-ASR sometimes spells an acronym said in Chinese speech as single capitals with a
/// space between them, even with the acronym in the vocabulary, and writes a few with a
/// period after each letter. Only text that holds Chinese characters is changed, so English
/// text stays as dictated:
/// - Two to five single capitals with one space between them become one word: 这个 P R 先别
///   merge is 这个 PR 先别 merge. A capital is single when no Latin letter touches it. The
///   letters stay apart when a Latin word is one space away, as in iPhone X S, since they
///   may belong to it.
/// - A byte unit spelled after a number joins the number: 16 G B is 16GB and 3.5G B is
///   3.5GB. Other capitals glued to a digit stay, as in 5G A 股.
/// - Two to four capitals that each end in a period lose the periods: O.K. is OK and A.I.
///   is AI. No Latin letter or period may come right before them, nor a Latin letter right
///   after.
///
/// Letters spelled on purpose stay apart: every letter of a dictation that talks about
/// spelling (拼写, 拼法, 怎么拼, 字母 or spell), and letters that spell a Latin word of the
/// same dictation, as in Lee 的拼写是 L E E. A lone capital stays, and so do six spelled
/// capitals or more and five dotted ones or more. Other letters meant apart, as in A B 两组,
/// are joined. Applying the rule twice gives the same text as applying it once.
nonisolated enum SpelledLetters {
    /// The byte units that NumberRules writes after a number, which join a number before
    /// them when spelled.
    private static let byteUnits: Set<String> = ["KB", "MB", "GB", "TB"]
    /// Words that say the letters of a dictation are spelled on purpose, in lower case.
    private static let spellingWords = ["拼写", "拼法", "怎么拼", "字母", "spell"]

    static func joining(in text: String) -> String {
        guard text.unicodeScalars.contains(where: ChineseText.isHan) else { return text }
        let characters = Array(text)
        guard characters.contains(where: isCapital) else { return text }
        let lowercased = text.lowercased()
        guard !spellingWords.contains(where: { lowercased.contains($0) }) else { return text }
        let words = latinWords(in: characters)
        return String(joiningSpelled(joiningDotted(characters, keeping: words), keeping: words))
    }

    /// The words of two Latin letters or more in the text, in lower case.
    private static func latinWords(in characters: [Character]) -> Set<String> {
        var words: Set<String> = []
        var word = ""
        for character in characters + [" "] {
            if character.isASCIILetter {
                word.append(character)
            } else {
                if word.count > 1 {
                    words.insert(word.lowercased())
                }
                word = ""
            }
        }
        return words
    }

    /// O.K. as OK. A run of capitals that each end in a period is taken whole, so a longer
    /// run, or one that a letter touches, stays as it is. So do letters that spell one of
    /// `words`.
    private static func joiningDotted(_ characters: [Character], keeping words: Set<String>) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            var end = index
            while end + 1 < characters.count, isCapital(characters[end]), characters[end + 1] == "." {
                end += 2
            }
            let count = (end - index) / 2
            guard count > 0 else {
                output.append(characters[index])
                index += 1
                continue
            }
            let letters = stride(from: index, to: end, by: 2).map { characters[$0] }
            let freeBefore = index == 0 || !(characters[index - 1].isASCIILetter || characters[index - 1] == ".")
            let freeAfter = end == characters.count || !characters[end].isASCIILetter
            if (2...4).contains(count), freeBefore, freeAfter, !words.contains(String(letters).lowercased()) {
                output.append(contentsOf: letters)
            } else {
                output.append(contentsOf: characters[index..<end])
            }
            index = end
        }
        return output
    }

    /// P R as PR, and a byte unit after a number as one word with it. A run of single
    /// capitals with one space between them is taken whole, so a longer run stays as it is.
    /// So do letters that spell one of `words`.
    private static func joiningSpelled(_ characters: [Character], keeping words: Set<String>) -> [Character] {
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            guard isSingleCapital(at: index, in: characters) else {
                output.append(characters[index])
                index += 1
                continue
            }
            // One past the last capital of the run.
            var end = index + 1
            while end + 1 < characters.count, characters[end] == " ", isSingleCapital(at: end + 1, in: characters) {
                end += 2
            }
            let count = (end - index + 1) / 2
            let letters = stride(from: index, to: end, by: 2).map { characters[$0] }
            let isUnit = byteUnits.contains(String(letters))
            let before: Character? = index > 0 ? characters[index - 1] : nil
            // A Latin word one space away, before or after the run.
            let wordBefore = before == " " && index > 1 && characters[index - 2].isASCIILetter
            let wordAfter = end + 1 < characters.count && characters[end] == " " && characters[end + 1].isASCIILetter
            let gluedToDigit = before.map(isDigit) ?? false
            let spellsAWord = words.contains(String(letters).lowercased())
            if (2...5).contains(count), !wordBefore, !wordAfter, !gluedToDigit || isUnit, !spellsAWord {
                // The space between a number and its unit goes too.
                if isUnit, before == " ", index > 1, isDigit(characters[index - 2]) {
                    output.removeLast()
                }
                output.append(contentsOf: letters)
            } else {
                output.append(contentsOf: characters[index..<end])
            }
            index = end
        }
        return output
    }

    /// A capital that no Latin letter touches.
    private static func isSingleCapital(at index: Int, in characters: [Character]) -> Bool {
        isCapital(characters[index])
            && (index == 0 || !characters[index - 1].isASCIILetter)
            && (index + 1 == characters.count || !characters[index + 1].isASCIILetter)
    }

    /// A to Z, not a capital with an accent.
    private static func isCapital(_ character: Character) -> Bool {
        character.isASCII && character.isUppercase
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
