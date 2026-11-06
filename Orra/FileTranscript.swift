import CoreFoundation
import Foundation

/// One segment of a file's transcript: what was said in it, and where it starts and ends
/// in the file, in seconds. Held in memory only, never logged.
nonisolated struct FileTranscriptSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

/// What Transcribe File gives the user: the text without times, for Copy and Save as
/// Text…, and SubRip subtitles, for Save as Subtitles…, with the names offered for them.
///
/// A subtitle has at most two lines of about 42 Latin characters, or about 18 Chinese or
/// Japanese ones, the common limits for subtitles. A segment whose text needs more becomes
/// as few subtitles in a row as it needs, of about the same length, which share its time in
/// proportion to their text. Lines and subtitles break where the text breaks best: after
/// the end of a sentence or a clause where one falls near the middle, never inside a word,
/// and in Chinese and Japanese at the words CFStringTokenizer finds.
nonisolated enum FileTranscript {
    /// The widest line, in Latin characters.
    static let lineWidth = 42.0
    /// A Chinese or Japanese character counts as 7 thirds of a Latin one, so a line holds
    /// 18 of them. Widths are counted in thirds, so they add up exactly.
    private static let thirdsPerLatinCharacter = 3
    private static let thirdsPerWideCharacter = 7
    /// The widest line, in thirds of a Latin character.
    private static let limit = Int(lineWidth) * thirdsPerLatinCharacter
    /// The most lines of one subtitle.
    static let linesPerSubtitle = 2
    /// The least time a subtitle shows, when its segment, or the pause after it, has it.
    static let shortestSubtitle = 1.0

    /// The two kinds of file Transcribe File saves.
    nonisolated enum Kind: Sendable {
        /// The text without times, one paragraph for each segment.
        case text
        /// SubRip subtitles.
        case subtitles

        var pathExtension: String {
            switch self {
            case .text: "txt"
            case .subtitles: "srt"
            }
        }
    }

    /// One subtitle: its lines, and when it shows, in seconds from the start of the file.
    nonisolated struct Subtitle: Equatable, Sendable {
        var start: Double
        var end: Double
        var lines: [String]
    }

    /// The text without times: each segment a paragraph of its own, on a line of its own.
    static func text(of segments: [FileTranscriptSegment]) -> String {
        segments.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The contents of a file of `kind`, ending with a line break.
    static func contents(of segments: [FileTranscriptSegment], as kind: Kind) -> String {
        let body = switch kind {
        case .text: text(of: segments)
        case .subtitles: subtitles(of: segments)
        }
        return body.isEmpty || body.hasSuffix("\n") ? body : body + "\n"
    }

    /// SubRip: the subtitles numbered from 1, each with its times as HH:MM:SS,mmm and its
    /// lines, and a blank line between them.
    static func subtitles(of segments: [FileTranscriptSegment]) -> String {
        subtitleList(of: segments).enumerated().map { index, subtitle in
            "\(index + 1)\n\(timestamp(subtitle.start)) --> \(timestamp(subtitle.end))\n" + subtitle.lines.joined(separator: "\n") + "\n"
        }
        .joined(separator: "\n")
    }

    /// The subtitles of the segments, in order. A segment without text gives none. A
    /// subtitle shorter than `shortestSubtitle`, such as a short answer, stays up into the
    /// pause after it, up to that long and never past the start of the next one.
    static func subtitleList(of segments: [FileTranscriptSegment]) -> [Subtitle] {
        let words = WordFinder()
        var subtitles = segments.flatMap { subtitles(of: $0, words: words) }
        for index in subtitles.indices where subtitles[index].end - subtitles[index].start < shortestSubtitle {
            let next = index + 1 < subtitles.count ? subtitles[index + 1].start : .infinity
            subtitles[index].end = max(subtitles[index].end, min(subtitles[index].start + shortestSubtitle, next))
        }
        return subtitles
    }

    /// The subtitles of one segment, as few as its text needs, see `Layout`, which share
    /// the segment's time in proportion to the width of their lines, see `shares(of:by:)`.
    static func subtitles(of segment: FileTranscriptSegment) -> [Subtitle] {
        subtitles(of: segment, words: WordFinder())
    }

    private static func subtitles(of segment: FileTranscriptSegment, words: WordFinder) -> [Subtitle] {
        let layout = Layout(segment.text, words: words)
        let lines = layout.subtitles().map(layout.lines(of:))
        let durations = shares(of: max(segment.end - segment.start, 0), by: lines.map { $0.reduce(0) { $0 + width(of: $1) } })
        var start = segment.start
        var subtitles: [Subtitle] = []
        for (index, lines) in lines.enumerated() {
            let end = index == durations.count - 1 ? segment.end : start + durations[index]
            subtitles.append(Subtitle(start: start, end: end, lines: lines))
            start = end
        }
        return subtitles
    }

    /// `span` shared in proportion to `widths`. When the span holds `shortestSubtitle` for
    /// each, a share that would be shorter gets that much, and the others give up the time
    /// in proportion to their widths.
    static func shares(of span: Double, by widths: [Double]) -> [Double] {
        var fixed = Set<Int>()
        while true {
            let left = span - shortestSubtitle * Double(fixed.count)
            let free = widths.indices.filter { !fixed.contains($0) }
            let total = free.reduce(0) { $0 + widths[$1] }
            let shares = widths.indices.map { index in
                fixed.contains(index) ? shortestSubtitle : (total > 0 ? left * widths[index] / total : left / Double(free.count))
            }
            let short = free.filter { shares[$0] < shortestSubtitle }
            guard span >= shortestSubtitle * Double(widths.count), !short.isEmpty else { return shares }
            fixed.formUnion(short)
        }
    }

    /// A time as SubRip writes it, HH:MM:SS,mmm, rounded to the millisecond.
    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let wholeSeconds = milliseconds / 1_000 % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, milliseconds % 1_000)
    }

    /// The name the save panel offers: the file's name with the extension of `kind` in
    /// place of its own. A name that is nothing but an extension gives Transcript.
    static func suggestedName(for fileName: String, as kind: Kind) -> String {
        let name = fileName as NSString
        var stem = name.pathExtension.isEmpty ? fileName : name.deletingPathExtension
        // A name such as “.m4a” is an extension alone, and a stem that starts with a dot
        // would make a hidden file.
        while stem.hasPrefix(".") {
            stem.removeFirst()
        }
        if fileName.hasPrefix("."), !fileName.dropFirst().contains(".") {
            stem = ""
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty {
            stem = String(localized: "Transcript")
        }
        return stem + "." + kind.pathExtension
    }

    // MARK: Lines

    /// The lines of the subtitles of a text, in order, see `Layout`.
    static func lines(of text: String) -> [String] {
        let layout = Layout(text, words: WordFinder())
        return layout.subtitles().flatMap(layout.lines(of:))
    }

    /// A part of a line that never breaks: a word with the punctuation around it, or a
    /// Chinese or Japanese word with the punctuation that closes after it.
    private struct Piece {
        var text = ""
        /// Whether a space stood before it in the text, which the line keeps.
        var spaceBefore = false

        /// The last character that is not a closing quote or bracket, such as the 。 of 。”.
        var lastMark: Character? {
            text.last { !FileTranscript.closers.contains($0) }
        }
    }

    /// The pieces of a text and where its lines and subtitles break.
    ///
    /// A subtitle takes as many pieces as fit in two lines, so the fewest subtitles a text
    /// needs come from filling each in turn. With that many, the subtitles are chosen to be
    /// about the same width, each break costing by where it falls, see `breakCost(before:)`,
    /// so a text of 37 Chinese characters makes two subtitles of about 18, not one of 36
    /// and one of a single character. A subtitle's text that fits on one line stays on one,
    /// and two lines are about the same width, broken the same way.
    private struct Layout {
        let pieces: [Piece]
        /// The widths of the pieces before each index, and of the spaces before them.
        private var widthsBefore = [0]
        private var spacesBefore = [0]
        /// For each piece, the end of the longest run from it that fits on one line.
        private var lineEnds: [Int] = []
        /// For each piece, the end of the longest run from it that fits in one subtitle.
        private var subtitleEnds: [Int] = []
        /// What a break after each piece costs, see `breakCost(before:)`.
        private var costsAfter: [Double] = []

        init(_ text: String, words: WordFinder) {
            pieces = FileTranscript.pieces(of: text, words: words)
            for piece in pieces {
                widthsBefore.append(widthsBefore[widthsBefore.count - 1] + FileTranscript.thirds(of: piece.text))
                spacesBefore.append(spacesBefore[spacesBefore.count - 1] + (piece.spaceBefore ? FileTranscript.thirdsPerLatinCharacter : 0))
            }
            // A run that fits on one line still fits without its first piece, so the ends
            // never go back. A piece wider than a line is a line of its own.
            var end = 0
            for start in pieces.indices {
                end = max(end, start + 1)
                while end < pieces.count, width(start..<(end + 1)) <= FileTranscript.limit {
                    end += 1
                }
                lineEnds.append(end)
            }
            costsAfter = pieces.map(Self.costOfBreak(after:))
            subtitleEnds = pieces.indices.map { start in
                var end = start
                for _ in 0..<FileTranscript.linesPerSubtitle where end < pieces.count {
                    end = lineEnds[end]
                }
                return end
            }
        }

        /// The width of a run of pieces on one line, with the spaces between them, in thirds
        /// of a Latin character.
        func width(_ run: Range<Int>) -> Int {
            guard !run.isEmpty else { return 0 }
            return widthsBefore[run.upperBound] - widthsBefore[run.lowerBound] + spacesBefore[run.upperBound] - spacesBefore[run.lowerBound + 1]
        }

        /// The runs of pieces of the subtitles, in order: as few as fit in two lines each,
        /// of about the same width, at the breaks that cost the least.
        func subtitles() -> [Range<Int>] {
            let count = pieces.count
            guard count > 0 else { return [] }
            var fewest = 0
            var start = 0
            while start < count {
                start = subtitleEnds[start]
                fewest += 1
            }
            guard fewest > 1 else { return [0..<count] }
            let target = Double(width(0..<count)) / Double(fewest)
            // cost[k][end] is the least cost of k subtitles that hold the pieces before
            // `end`, and starts[k][end] where the last of them starts. How far a subtitle is
            // from the target width counts half as much as in a line, so a subtitle ends at
            // the end of a sentence or a clause a little further from the middle.
            var cost = Array(repeating: Array(repeating: Double.infinity, count: count + 1), count: fewest + 1)
            var starts = Array(repeating: Array(repeating: 0, count: count + 1), count: fewest + 1)
            cost[0][0] = 0
            for k in 1...fewest {
                for start in 0..<count where cost[k - 1][start] < .infinity {
                    for end in (start + 1)...subtitleEnds[start] {
                        let off = (Double(width(start..<end)) - target) / Double(FileTranscript.limit)
                        let total = cost[k - 1][start] + off * off / 2 + (end < count ? breakCost(before: end) : 0)
                        if total < cost[k][end] {
                            cost[k][end] = total
                            starts[k][end] = start
                        }
                    }
                }
            }
            var runs: [Range<Int>] = []
            var end = count
            for k in stride(from: fewest, to: 0, by: -1) {
                let start = starts[k][end]
                runs.insert(start..<end, at: 0)
                end = start
            }
            return runs
        }

        /// The lines of a subtitle's run: one when it fits, else two of about the same width
        /// at the break that costs the least.
        func lines(of run: Range<Int>) -> [String] {
            guard lineEnds[run.lowerBound] < run.upperBound else { return [joined(run)] }
            var best: (cost: Double, at: Int)?
            for at in (run.lowerBound + 1)..<run.upperBound where at <= lineEnds[run.lowerBound] && lineEnds[at] >= run.upperBound {
                let off = Double(width(run.lowerBound..<at) - width(at..<run.upperBound)) / Double(FileTranscript.limit)
                let cost = off * off + breakCost(before: at)
                if cost < best?.cost ?? .infinity {
                    best = (cost, at)
                }
            }
            guard let at = best?.at else { return [joined(run)] }
            return [joined(run.lowerBound..<at), joined(at..<run.upperBound)]
        }

        /// What a break before piece `index` costs.
        private func breakCost(before index: Int) -> Double {
            costsAfter[index - 1]
        }

        /// What a break after `piece` costs: nothing after the end of a sentence, a little
        /// after a comma or another mark that ends a clause, more between two words, and
        /// more still after a word that leads into the next, such as “the” or “de”.
        private static func costOfBreak(after piece: Piece) -> Double {
            if let mark = piece.lastMark, FileTranscript.sentenceEnds.contains(mark) {
                return 0
            }
            if let mark = piece.lastMark, FileTranscript.clauseEnds.contains(mark) {
                return 0.1
            }
            return FileTranscript.leadingWords.contains(piece.text.lowercased()) ? 0.6 : 0.4
        }

        private func joined(_ run: Range<Int>) -> String {
            var line = ""
            for piece in pieces[run] {
                if !line.isEmpty, piece.spaceBefore {
                    line += " "
                }
                line += piece.text
            }
            return line
        }
    }

    /// Punctuation that ends a sentence, after which a line breaks best.
    fileprivate static let sentenceEnds: Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
    /// Punctuation that ends a clause, after which a line breaks well.
    fileprivate static let clauseEnds: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]
    /// Closing quotes and brackets, which a sentence or a clause may end inside.
    fileprivate static let closers: Set<Character> = Set("）」』”’》〉】〕)]}")
    /// Words of English and Spanish that lead into the word after them, so a line breaks
    /// better before them than after them.
    fileprivate static let leadingWords: Set<String> = [
        "a", "an", "the", "of", "to", "and", "or", "in", "on", "at", "for", "with",
        "el", "la", "los", "las", "un", "una", "de", "del", "al", "y", "o", "en", "con", "por", "para",
    ]
    /// Characters that never start a line: closing punctuation, and the small kana and
    /// the long vowel mark of Japanese.
    private static let neverFirst: Set<Character> = Set("，。、；：！？）」』”’》〉】〕…,.;:!?)]}%ーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ々")
    /// Characters that never end a line: opening punctuation.
    private static let neverLast: Set<Character> = Set("（「『“‘《〈【〔([{")
    /// Chinese particles that end the word before them and never start a line, such as
    /// the 的 of 我们的.
    private static let chineseEndings: Set<String> = ["的", "地", "得", "了", "着", "过", "吗", "呢", "吧", "啊", "们"]

    /// How a word of Chinese or Japanese starts, for where a line may break before it.
    private enum WordStart {
        /// A word of its own, before which a line may break.
        case word
        /// A word that ends the one before it: a Chinese particle such as 的, or what
        /// Japanese writes in hiragana after a word, such as the particle を or the ending
        /// ました, so a line breaks before a word with its particles, not inside it.
        case ending
    }

    private static func pieces(of text: String, words finder: WordFinder) -> [Piece] {
        let words = finder.starts(in: text)
        var pieces: [Piece] = []
        var current = Piece()
        var sawSpace = false
        func close() {
            if !current.text.isEmpty {
                pieces.append(current)
            }
            current = Piece()
        }
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace || character.isNewline {
                close()
                sawSpace = true
                continue
            }
            if let last = current.text.last, mayBreak(between: last, and: character, startingWord: words[index], after: current) {
                close()
            }
            if current.text.isEmpty {
                current.spaceBefore = sawSpace && !pieces.isEmpty
                sawSpace = false
            }
            current.text.append(character)
        }
        close()
        return pieces
    }

    /// Whether a line may break between `last`, the end of `piece`, and `next`, with no
    /// space between them: never after punctuation that opens or before punctuation that
    /// closes, nor inside a run of Latin letters, digits and symbols, nor between a number
    /// and the Chinese or Japanese character after it, as in 15米. Between two Chinese or
    /// Japanese characters only where a word starts, and before an ending only once the
    /// piece fills half a line, so a long run of hiragana still breaks.
    private static func mayBreak(between last: Character, and next: Character, startingWord word: WordStart?, after piece: Piece) -> Bool {
        if neverLast.contains(last) || neverFirst.contains(next) {
            return false
        }
        switch (isWide(last), isWide(next)) {
        case (false, false):
            return false
        case (false, true):
            return !last.isNumber
        case (true, false):
            return true
        case (true, true):
            switch word {
            case .word: return true
            case .ending: return thirds(of: piece.text) >= limit / 2
            case nil: return false
            }
        }
    }

    /// Finds where the words of a text start, as CFStringTokenizer finds them. In the root
    /// locale, which it uses without one, it finds the words of both Chinese and Japanese,
    /// where a Chinese or a Japanese locale breaks the words of the other apart.
    ///
    /// It keeps one tokenizer for the texts it is given, since making a tokenizer takes more
    /// than 10 times as long as giving it another text, which adds up over the thousands of
    /// segments of a long file. Each call that lays out text makes its own finder, so none
    /// is used by two threads.
    private final class WordFinder {
        private var tokenizer: CFStringTokenizer?

        func starts(in text: String) -> [String.Index: WordStart] {
            guard text.contains(where: FileTranscript.isWide) else { return [:] }
            let whole = CFRange(location: 0, length: (text as NSString).length)
            let tokenizer: CFStringTokenizer
            if let reused = self.tokenizer {
                CFStringTokenizerSetString(reused, text as CFString, whole)
                tokenizer = reused
            } else {
                tokenizer = CFStringTokenizerCreate(nil, text as CFString, whole, kCFStringTokenizerUnitWordBoundary, nil)
                self.tokenizer = tokenizer
            }
            var starts: [String.Index: WordStart] = [:]
            var previous: Substring?
            while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
                let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                guard let range = Range(NSRange(location: token.location, length: token.length), in: text) else { continue }
                let word = text[range]
                let afterWord = previous?.last.map { FileTranscript.isWide($0) && !$0.isPunctuation } ?? false
                let isEnding = afterWord && (word.allSatisfy(FileTranscript.isHiragana) || FileTranscript.chineseEndings.contains(String(word)))
                starts[range.lowerBound] = isEnding ? .ending : .word
                previous = word
            }
            return starts
        }
    }

    private static func thirds(of text: String) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? thirdsPerWideCharacter : thirdsPerLatinCharacter) }
    }

    /// The width of a text in Latin characters, a Chinese or Japanese character counting
    /// as 7 thirds of one.
    static func width(of text: String) -> Double {
        Double(thirds(of: text)) / Double(thirdsPerLatinCharacter)
    }

    /// Chinese characters, Japanese kana, Korean and full width forms and punctuation.
    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
                 0x20000...0x3FFFD:
                true
            default:
                false
            }
        }
    }

    /// Hiragana, small kana included.
    private static func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }
}
