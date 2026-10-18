import Accelerate
import Foundation

/// What the speech model wrote for one piece of a recording.
nonisolated struct TranscribedPiece: Equatable, Sendable {
    /// The text, or nil when the piece failed.
    var text: String?
    /// How long the piece's audio is.
    var seconds: Double
}

/// Cuts a long recording into pieces that the speech model transcribes one after another,
/// and joins what it wrote for them.
///
/// One pass over a whole recording slows down with about the square of its length, and on
/// 20 minutes it lost the last seconds of speech. Pieces of at most a minute were as
/// accurate as the same clips one by one at every length from 1 to 20 minutes, kept the
/// speech model's memory at 4.1 GB, and took about 2 s per minute of speech on an M5 Pro.
/// That was measured on 2026-10-17 with clips of the speech corpus joined into long
/// recordings, through the path of a dictation in a Release build.
///
/// Each cut lands in the middle of the quietest 0.3 s within the last 15 s of a full piece,
/// so it falls into a pause between sentences or words. Speech without a pause there is
/// cut at its quietest moment all the same, between syllables at worst, which can garble
/// the word at the cut. A recording of up to a minute is one piece.
nonisolated enum RecordingPieces {
    /// The longest piece.
    static let maximumSeconds = 60.0
    /// How far before the end of a full piece its cut may land.
    static let searchSeconds = 15.0
    /// The windows compared for the cut, and the step between them.
    static let windowSeconds = 0.3
    static let stepSeconds = 0.01
    /// The shortest piece after a cut, so a recording just over a minute does not end in a
    /// sliver the model can make little of.
    static let minimumSeconds = 1.0

    /// The pieces of `samples` at `sampleRate`, in order. Together they are the whole
    /// recording, and each is at most `maximumSeconds` long.
    static func bounds(of samples: [Float], sampleRate: Int = RecordingLimits.sampleRate) -> [Range<Int>] {
        let rate = Double(sampleRate)
        let limit = Int(maximumSeconds * rate)
        let search = Int(searchSeconds * rate)
        let window = max(Int(windowSeconds * rate), 1)
        let step = max(Int(stepSeconds * rate), 1)
        let minimum = Int(minimumSeconds * rate)
        var pieces: [Range<Int>] = []
        var start = 0
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            while samples.count - start > limit {
                // The window may not reach past the full piece, nor into the shortest
                // piece that has to follow.
                let end = min(start + limit, samples.count - minimum)
                var cut = end
                var lowest = Float.greatestFiniteMagnitude
                var index = start + limit - search
                while index + window <= end {
                    var energy: Float = 0
                    vDSP_svesq(base + index, 1, &energy, vDSP_Length(window))
                    if energy < lowest {
                        lowest = energy
                        cut = index + window / 2
                    }
                    index += step
                }
                pieces.append(start..<cut)
                start = cut
            }
        }
        pieces.append(start..<samples.count)
        return pieces
    }

    /// The text of a dictation from what the speech model wrote for its pieces, and how
    /// many pieces failed. Each text goes through TranscriptGuard for the length of its own
    /// piece and into simplified characters, as a whole recording did before, so one piece
    /// gives exactly the text it always did. An empty piece is not missing: the speech
    /// model writes nothing for silence, such as a long pause to think or the quiet before
    /// the key stopped the recording.
    static func transcript(of pieces: [TranscribedPiece]) -> (text: String, missing: Int) {
        let texts = pieces.compactMap { piece in
            piece.text.map { ChineseText.simplified(TranscriptGuard.clean($0, audioSeconds: piece.seconds)) }
        }
        return (joined(texts), pieces.count(where: { $0.text == nil }))
    }

    /// Joins texts the way their language needs. Chinese runs on without a space, and so
    /// does anything after full width punctuation such as 。 or ，, and before punctuation.
    /// Elsewhere a space goes between: between English words, after a period, and between
    /// a Chinese and an English word, as the speech model writes them within one piece. No
    /// punctuation is added, so a piece cut inside a sentence runs on into the next one.
    /// Empty texts are left out.
    static func joined(_ texts: [String]) -> String {
        var result = ""
        for text in texts where !text.isEmpty {
            if let last = result.last, let first = text.first, needsSpace(after: last, before: first) {
                result += " "
            }
            result += text
        }
        return result
    }

    private static func needsSpace(after last: Character, before first: Character) -> Bool {
        if last.isWhitespace || first.isWhitespace || (last.isWide && first.isWide) {
            return false
        }
        if last.isWide && last.isPunctuation {
            return false
        }
        return !first.isPunctuation || Self.openingPunctuation.contains(first)
    }

    /// Punctuation that opens what follows, so a space may go before it.
    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "“", "‘", "\"", "'", "（", "「", "『", "《", "【"]
}

nonisolated private extension Character {
    /// Chinese characters, Japanese kana, and full width and Chinese punctuation, which
    /// run on without spaces.
    var isWide: Bool {
        unicodeScalars.allSatisfy { ChineseText.isHan($0) || (0x3000...0x30FF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
