import Foundation

/// Cuts the text of a file into chunks for the index.
///
/// - A chunk holds at most `size` characters. Qwen counts 1.5 to 1.8 Chinese characters a
///   token, so 800 characters are about 500 tokens.
/// - Cuts fall at headings, blank lines and sentence ends. Only a paragraph with no sentence
///   end near its cut is cut at a line break, a space, or anywhere.
/// - A chunk never spans two pages.
/// - Within a section, a chunk repeats about the last `overlap` characters of the one before,
///   so a sentence cut in two is whole in one of them. A chunk that starts at a heading
///   repeats nothing.
/// - Each chunk keeps its file, its page, the file's modification date and the heading above
///   its first line, which may sit on an earlier page.
nonisolated struct TextChunker: Sendable {
    nonisolated struct Chunk: Sendable, Equatable {
        var file: URL
        /// The page number in a PDF, nil for the other formats.
        var page: Int?
        var modified: Date
        /// The heading above the chunk's first line, nil before the file's first heading.
        var heading: String?
        var text: String
    }

    /// The most characters in a chunk.
    var size = 800
    /// The characters a chunk repeats from the one before it, 15% of `size`.
    var overlap = 120

    func chunks(of text: FileTextResult, file: URL) -> [Chunk] {
        var chunks: [Chunk] = []
        var heading: String?
        for page in text.pages {
            var current = ""
            var currentCount = 0
            var currentHeading = heading
            func close() {
                if currentCount > 0 {
                    chunks.append(Chunk(file: file, page: page.number, modified: text.modified, heading: currentHeading, text: current))
                }
                current = ""
                currentCount = 0
            }
            for paragraph in Self.paragraphs(of: page.text) {
                let opening = Self.heading(in: paragraph)
                for (index, piece) in cut(paragraph).enumerated() {
                    let pieceCount = piece.count
                    let opensSection = index == 0 && opening != nil
                    if opensSection {
                        // A heading starts a new chunk, unless the chunk so far is short.
                        if currentCount >= size / 4 { close() }
                        heading = opening
                        if currentCount == 0 { currentHeading = heading }
                    }
                    if currentCount > 0 && currentCount + 2 + pieceCount > size {
                        let repeated = opensSection ? "" : tail(of: current)
                        close()
                        current = repeated
                        currentCount = repeated.count
                        currentHeading = heading
                    }
                    if currentCount > 0 {
                        current += "\n\n"
                        currentCount += 2
                    }
                    current += piece
                    currentCount += pieceCount
                }
            }
            close()
        }
        return chunks
    }

    // MARK: Paragraphs and pieces

    /// The paragraphs of a page, split at blank lines and trimmed.
    static func paragraphs(of text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [Substring] = []
        func flush() {
            let paragraph = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            lines = []
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) {
                flush()
            } else {
                lines.append(line)
            }
        }
        flush()
        return paragraphs
    }

    /// `paragraph` in pieces short enough that a piece with the repeat in front of it fits a
    /// chunk. A cut falls after the last sentence end in the second half of the piece, or
    /// else after the last line break or space there, or at the limit.
    private func cut(_ paragraph: String) -> [String] {
        let limit = max(1, size - overlap - 2)
        let characters = Array(paragraph)
        guard characters.count > limit else { return [paragraph] }
        var pieces: [String] = []
        var start = 0
        while characters.count - start > limit {
            let end = Self.cutPoint(in: characters, from: start, limit: limit)
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            start = end
            while start < characters.count && characters[start].isWhitespace { start += 1 }
        }
        let rest = String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { pieces.append(rest) }
        return pieces
    }

    private static func cutPoint(in characters: [Character], from start: Int, limit: Int) -> Int {
        let end = start + limit
        let candidates = (start + limit / 2)..<end
        if let found = candidates.last(where: { isSentenceEnd(characters, at: $0) }) {
            var cut = found + 1
            while cut < end && closings.contains(characters[cut]) { cut += 1 }
            return cut
        }
        if let found = candidates.last(where: { characters[$0].isNewline }) { return found + 1 }
        if let found = candidates.last(where: { characters[$0].isWhitespace }) { return found + 1 }
        return end
    }

    /// The last `overlap` characters of `text`, so the repeat starts at a sentence or a
    /// word: from just after their first sentence end that leaves at least a third of them,
    /// or else after the first space in their first half.
    private func tail(of text: String) -> String {
        let characters = Array(text.suffix(overlap))
        let start = (0..<max(0, characters.count - overlap / 3)).first(where: { Self.isSentenceEnd(characters, at: $0) })
            ?? (0..<min(characters.count, overlap / 2)).first(where: { characters[$0].isWhitespace })
        guard let start else { return String(characters) }
        return String(characters[(start + 1)...].drop(while: { $0.isWhitespace || Self.closings.contains($0) }))
    }

    /// Ends of a sentence in Chinese and English. A period counts only before white space,
    /// a closing quote or the end, so 3.5 stays whole.
    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "…"]
    /// Closing quotes and brackets, which stay with the sentence they end.
    private static let closings: Set<Character> = ["”", "\"", "’", "'", "）", ")", "」", "』"]

    private static func isSentenceEnd(_ characters: [Character], at index: Int) -> Bool {
        let character = characters[index]
        if sentenceEnds.contains(character) { return true }
        guard character == "." else { return false }
        let next = index + 1
        return next == characters.count || characters[next].isWhitespace || closings.contains(characters[next])
    }

    // MARK: Headings

    /// The heading a paragraph starts with, read from its first line: a Markdown heading, a
    /// short numbered line such as "2. Payment" or "二、付款", a part such as "第三条", or a
    /// short line that ends with a colon. A line that ends like a sentence is not a heading.
    static func heading(in paragraph: String) -> String? {
        guard let first = paragraph.split(whereSeparator: \.isNewline).first else { return nil }
        let line = Array(first.trimmingCharacters(in: .whitespaces))
        if line.first == "#" {
            let marks = line.prefix(while: { $0 == "#" }).count
            guard marks <= 6, marks < line.count, line[marks] == " " else { return nil }
            let title = String(line[marks...]).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        guard let last = line.last, line.count <= 40 else { return nil }
        if last == ":" || last == "：" {
            return (3...31).contains(line.count) ? String(line.dropLast()).trimmingCharacters(in: .whitespaces) : nil
        }
        if headingEnds.contains(last) { return nil }
        return isNumbered(line) ? String(line) : nil
    }

    private static let headingEnds: Set<Character> = ["。", "！", "？", "；", "，", "!", "?", ";", ".", ","]
    private static let chineseNumerals: Set<Character> = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "零", "〇"]

    /// Whether `line` starts with a number and goes on with a title: "2. Payment", "1.2 Scope",
    /// "3) Fees", "二、付款", "第三条 付款" or "（一）付款".
    private static func isNumbered(_ line: [Character]) -> Bool {
        func isDigit(_ index: Int) -> Bool { index < line.count && line[index].isASCII && line[index].isNumber }
        func isNumeral(_ index: Int) -> Bool { isDigit(index) || (index < line.count && chineseNumerals.contains(line[index])) }
        var index = 0
        if isDigit(0) {
            while isDigit(index) { index += 1 }
            var hasParts = false
            while index + 1 < line.count && line[index] == "." && isDigit(index + 1) {
                hasParts = true
                index += 1
                while isDigit(index) { index += 1 }
            }
            guard index + 1 < line.count else { return false }
            // "1.2 Scope" is a heading, "3.5 percent" is not.
            return [".", ")", "、", "．", "）"].contains(line[index]) || (hasParts && line[index] == " " && !line[index + 1].isLowercase)
        }
        if line.first == "第" {
            index = 1
            while isNumeral(index) { index += 1 }
            return index > 1 && index < line.count && ["章", "节", "条", "部", "篇"].contains(line[index])
        }
        if line.first == "(" || line.first == "（" {
            index = 1
            while isNumeral(index) { index += 1 }
            return index > 1 && index + 1 < line.count && (line[index] == ")" || line[index] == "）")
        }
        while index < line.count && chineseNumerals.contains(line[index]) { index += 1 }
        return index > 0 && index + 1 < line.count && ["、", ".", "．"].contains(line[index])
    }
}
