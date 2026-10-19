import Foundation

/// Cuts a translation into the pieces the voice speaks one after another. The first
/// sentence can play while the voice model works on the next, so a long translation
/// starts sooner, and the model never gets a text longer than it says well.
nonisolated enum SpeechChunks {
    /// The longest piece, in characters. Qwen3-TTS caps its output by the length of its
    /// text, and a long piece makes the listener wait for all of it, so a long sentence is
    /// cut further at a comma, and at a space or anywhere as a last resort.
    static let maximumLength = 80

    /// A piece shorter than this, such as "OK." or "好的。", joins the next one, so the
    /// voice does not stop after every short word.
    static let minimumLength = 6

    /// The pieces of `text` in order. Together they hold every character of `text` that is
    /// not white space at a cut. Empty for a text of white space only.
    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        for sentence in sentences(of: text) {
            pieces += cut(sentence)
        }
        return joiningShort(pieces)
    }

    /// Ends of a sentence in Chinese, Japanese, English and Spanish text. A period counts
    /// only before white space, a closing quote or the end, so 3.5 stays whole, and not
    /// after an abbreviation such as Dr., Sra. or e.g.
    private static let strongEnds: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n", "…"]
    private static let weakEnds: Set<Character> = ["，", ",", "、", "：", ":"]
    /// Closing quotes and brackets, which stay with the sentence they end.
    private static let closings: Set<Character> = ["”", "\"", "’", "'", "）", ")", "」", "』"]

    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            let next = index < characters.count ? characters[index] : nil
            let isEnd = strongEnds.contains(character)
                || (character == "." && (next.map { $0.isWhitespace || closings.contains($0) } ?? true)
                    && !isAbbreviation(characters[..<(index - 1)]))
            guard isEnd else { continue }
            while index < characters.count, strongEnds.contains(characters[index]) || closings.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            append(current, to: &result)
            current = ""
        }
        append(current, to: &result)
        return result
    }

    /// Titles that come before a name and end with a period.
    private static let titles: Set<String> = ["Mr", "Mrs", "Ms", "Dr", "Prof", "St", "vs", "Sr", "Sra", "Srta", "Dra", "Lic", "Ing", "Ud", "Uds"]

    /// Whether the word at the end of `text`, just before a period, is an abbreviation:
    /// a title such as Dr, or letters with periods between them such as e.g, U.S or p.m.
    private static func isAbbreviation(_ text: ArraySlice<Character>) -> Bool {
        let start = text.lastIndex(where: { $0.isWhitespace || closings.contains($0) || "“‘(\"".contains($0) })
            .map { $0 + 1 } ?? text.startIndex
        let word = text[start...]
        if titles.contains(String(word)) {
            return true
        }
        let letters = word.split(separator: ".", omittingEmptySubsequences: false)
        return letters.count > 1 && letters.allSatisfy { $0.count == 1 && $0.allSatisfy(\.isLetter) }
    }

    /// Cuts a sentence that is too long at its commas, then at spaces, then anywhere. A
    /// Latin comma or colon between two digits is not a cut, so 1,000 and 2:30 stay whole.
    private static func cut(_ sentence: String) -> [String] {
        guard sentence.count > maximumLength else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        let characters = Array(sentence)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let inNumber = character.isASCII && index > 0 && index + 1 < characters.count
                && isDigit(characters[index - 1]) && isDigit(characters[index + 1])
            if weakEnds.contains(character), !inNumber, current.count >= minimumLength {
                append(current, to: &pieces)
                current = ""
            }
        }
        append(current, to: &pieces)
        return pieces.flatMap { piece -> [String] in
            guard piece.count > maximumLength else { return [piece] }
            return hardCut(piece)
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isWholeNumber
    }

    /// The last resort: at the last space before the limit, or at the limit for Chinese text
    /// without spaces.
    private static func hardCut(_ piece: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(piece)
        while rest.count > maximumLength {
            let window = rest.prefix(maximumLength)
            let end = window.lastIndex(where: \.isWhitespace).flatMap { $0 > window.startIndex ? $0 : nil } ?? window.endIndex
            append(String(rest[..<end]), to: &pieces)
            rest = rest[end...]
        }
        append(String(rest), to: &pieces)
        return pieces
    }

    /// Joins a short piece to the one after it, and a short last piece to the one before.
    private static func joiningShort(_ pieces: [String]) -> [String] {
        var result: [String] = []
        for piece in pieces {
            if let last = result.last, last.count < minimumLength, join(last, piece).count <= maximumLength {
                result[result.count - 1] = join(last, piece)
            } else {
                result.append(piece)
            }
        }
        if result.count > 1, let last = result.last, last.count < minimumLength,
           join(result[result.count - 2], last).count <= maximumLength {
            result.removeLast()
            result[result.count - 1] = join(result[result.count - 1], last)
        }
        return result
    }

    /// Two pieces with a space between them when both sides are Latin text.
    private static func join(_ first: String, _ second: String) -> String {
        guard let end = first.last, let start = second.first else { return first + second }
        return end.isASCII && start.isASCII ? first + " " + second : first + second
    }

    private static func append(_ piece: String, to pieces: inout [String]) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            pieces.append(trimmed)
        }
    }
}
