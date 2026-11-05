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
/// Japanese ones, the common limits for subtitles. A segment whose text needs more lines
/// becomes several subtitles in a row, which share its time in proportion to their text.
nonisolated enum FileTranscript {
    /// The widest line, in Latin characters.
    static let lineWidth = 42.0
    /// A Chinese or Japanese character counts as 7 thirds of a Latin one, so a line holds
    /// 18 of them. Widths are counted in thirds, so they add up exactly.
    private static let thirdsPerLatinCharacter = 3
    private static let thirdsPerWideCharacter = 7
    /// The most lines of one subtitle.
    static let linesPerSubtitle = 2

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

    /// The subtitles of the segments, in order. A segment without text gives none.
    static func subtitleList(of segments: [FileTranscriptSegment]) -> [Subtitle] {
        segments.flatMap(subtitles(of:))
    }

    /// The subtitles of one segment: its lines, two to a subtitle, with the segment's time
    /// shared in proportion to the width of their text.
    static func subtitles(of segment: FileTranscriptSegment) -> [Subtitle] {
        let lines = lines(of: segment.text)
        guard !lines.isEmpty else { return [] }
        let groups = stride(from: 0, to: lines.count, by: linesPerSubtitle).map {
            Array(lines[$0..<min($0 + linesPerSubtitle, lines.count)])
        }
        let widths = groups.map { $0.reduce(0) { $0 + width(of: $1) } }
        let total = widths.reduce(0, +)
        let span = max(segment.end - segment.start, 0)
        var subtitles: [Subtitle] = []
        var before = 0.0
        for (index, group) in groups.enumerated() {
            let start = segment.start + span * before / total
            before += widths[index]
            let end = index == groups.count - 1 ? segment.end : segment.start + span * before / total
            subtitles.append(Subtitle(start: start, end: end, lines: group))
        }
        return subtitles
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

    /// The text cut into lines of at most `lineWidth`. A line breaks at a space, or
    /// between two Chinese or Japanese characters, never before punctuation that closes,
    /// such as ， or 。, nor after punctuation that opens, such as “ or （. When a line is
    /// full, it breaks after the last comma or end of a sentence in its second half, if it
    /// has one. A single word wider than a line keeps a line of its own.
    static func lines(of text: String) -> [String] {
        var lines: [[Piece]] = []
        var line: [Piece] = []
        let limit = Int(lineWidth) * thirdsPerLatinCharacter
        for piece in pieces(of: text) {
            guard !line.isEmpty, width(of: line + [piece]) > limit else {
                line.append(piece)
                continue
            }
            // The last clause of the line ends it when it ends in the line's second half,
            // and what follows it moves on with the new piece.
            var keep = line.count
            for count in stride(from: line.count, through: 1, by: -1) where line[count - 1].endsClause {
                if width(of: Array(line[..<count])) >= limit / 2 {
                    keep = count
                }
                break
            }
            lines.append(Array(line[..<keep]))
            line = Array(line[keep...])
            if !line.isEmpty, width(of: line + [piece]) > limit {
                lines.append(line)
                line = []
            }
            line.append(piece)
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines.map(joined)
    }

    /// A part of a line that never breaks: a word with the punctuation around it, or one
    /// Chinese or Japanese character with the punctuation that closes after it.
    private struct Piece {
        var text = ""
        /// Whether a space stood before it in the text, which the line keeps.
        var spaceBefore = false

        var endsClause: Bool {
            text.last.map { FileTranscript.clauseEnds.contains($0) } ?? false
        }
    }

    /// Punctuation that ends a sentence or a clause, after which a line breaks well.
    fileprivate static let clauseEnds: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", ",", ".", ";", ":", "!", "?", "…"]
    /// Characters that never start a line: closing punctuation, and the small kana and
    /// the long vowel mark of Japanese.
    private static let neverFirst: Set<Character> = Set("，。、；：！？）」』”’》〉】〕…,.;:!?)]}%ーぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ々")
    /// Characters that never end a line: opening punctuation.
    private static let neverLast: Set<Character> = Set("（「『“‘《〈【〔([{")

    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = Piece()
        var sawSpace = false
        func close() {
            if !current.text.isEmpty {
                pieces.append(current)
            }
            current = Piece()
        }
        for character in text {
            if character.isWhitespace || character.isNewline {
                close()
                sawSpace = true
                continue
            }
            // A character joins the piece when no line may break before it: after opening
            // punctuation, before closing punctuation, and inside a run of Latin letters,
            // digits and symbols. A space always ends a piece.
            if let last = current.text.last,
               !(neverLast.contains(last) || neverFirst.contains(character) || (!isWide(last) && !isWide(character))) {
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

    private static func joined(_ pieces: [Piece]) -> String {
        var line = ""
        for piece in pieces {
            if !line.isEmpty, piece.spaceBefore {
                line += " "
            }
            line += piece.text
        }
        return line
    }

    /// The width of pieces in a line, in thirds of a Latin character.
    private static func width(of pieces: [Piece]) -> Int {
        thirds(of: joined(pieces))
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
}
