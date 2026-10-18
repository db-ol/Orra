import Foundation
import Testing
@testable import Orra

/// Cutting a long recording into pieces and joining what the speech model wrote for them,
/// on made up audio.
struct RecordingPiecesTests {
    static let rate = RecordingLimits.sampleRate

    /// A loud tone that stands in for speech without a pause.
    static func speech(seconds: Double, rate: Int = rate) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    }

    /// Faint noise that stands in for a pause, about 50 dB below the tone.
    static func pause(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 0.31)) * 0.001 }
    }

    static func seconds(_ samples: Int) -> Double {
        Double(samples) / Double(rate)
    }

    /// The pieces cover the recording in order, without gaps or overlaps, and none is
    /// longer than a minute.
    private static func expectCover(_ bounds: [Range<Int>], of count: Int, rate: Int = rate) {
        #expect(bounds.first?.lowerBound == 0)
        #expect(bounds.last?.upperBound == count)
        for (piece, next) in zip(bounds, bounds.dropFirst()) {
            #expect(piece.upperBound == next.lowerBound)
        }
        for piece in bounds {
            #expect(!piece.isEmpty)
            #expect(Double(piece.count) <= RecordingPieces.maximumSeconds * Double(rate))
        }
    }

    @Test func aMinuteOrLessIsOnePiece() {
        #expect(RecordingPieces.bounds(of: []) == [0..<0])
        let short = Self.speech(seconds: 3)
        #expect(RecordingPieces.bounds(of: short) == [0..<short.count])
        let minute = Self.speech(seconds: 60)
        #expect(RecordingPieces.bounds(of: minute) == [0..<minute.count])
    }

    @Test func theCutLandsInAPause() {
        let samples = Self.speech(seconds: 50) + Self.pause(seconds: 0.6) + Self.speech(seconds: 49.4)
        let bounds = RecordingPieces.bounds(of: samples)
        Self.expectCover(bounds, of: samples.count)
        #expect(bounds.count == 2)
        let cut = Self.seconds(bounds[0].upperBound)
        #expect(cut > 50.1 && cut < 50.5, "cut at \(cut) s")
    }

    /// A pause too early in the piece is not used, so pieces stay close to a minute.
    @Test func aPauseBeforeTheLastFifteenSecondsIsNotUsed() {
        let samples = Self.speech(seconds: 30) + Self.pause(seconds: 1) + Self.speech(seconds: 59)
        let bounds = RecordingPieces.bounds(of: samples)
        Self.expectCover(bounds, of: samples.count)
        let cut = Self.seconds(bounds[0].upperBound)
        #expect(cut >= 45 && cut <= 60, "cut at \(cut) s")
    }

    /// Speech without a pause is still cut, at its quietest moment in the last 15 s of
    /// each piece.
    @Test func speechWithoutPausesIsCutInTheLastFifteenSeconds() {
        let samples = Self.speech(seconds: 300)
        let bounds = RecordingPieces.bounds(of: samples)
        Self.expectCover(bounds, of: samples.count)
        #expect((5...7).contains(bounds.count))
        for piece in bounds.dropLast() {
            let length = Self.seconds(piece.count)
            #expect(length >= 45 && length < 60, "piece of \(length) s")
        }
    }

    /// Five minutes of sentences of 6 to 12 s with short pauses: every cut lands in a pause.
    @Test func fiveMinutesOfSentencesAreCutBetweenThem() {
        var samples: [Float] = []
        var pauses: [Range<Int>] = []
        var sentence = 0
        while Self.seconds(samples.count) < 300 {
            samples += Self.speech(seconds: 6 + Double(sentence % 7))
            let start = samples.count
            samples += Self.pause(seconds: 0.5)
            pauses.append(start..<samples.count)
            sentence += 1
        }
        let bounds = RecordingPieces.bounds(of: samples)
        Self.expectCover(bounds, of: samples.count)
        #expect(bounds.count >= 6)
        for piece in bounds.dropLast() {
            #expect(pauses.contains { $0.contains(piece.upperBound) }, "cut at \(Self.seconds(piece.upperBound)) s")
        }
    }

    /// A recording just over a minute does not end in a piece shorter than a second, even
    /// when its quietest moment comes right before the end.
    @Test func theLastPieceKeepsASecond() {
        let samples = Self.speech(seconds: 59.6) + Self.pause(seconds: 0.7)
        let bounds = RecordingPieces.bounds(of: samples)
        Self.expectCover(bounds, of: samples.count)
        #expect(bounds.count == 2)
        #expect(Self.seconds(bounds[1].count) >= RecordingPieces.minimumSeconds)
    }

    @Test func otherSampleRatesAreCutByTheirTime() {
        let rate = 48_000
        let samples = Self.speech(seconds: 61, rate: rate)
        let bounds = RecordingPieces.bounds(of: samples, sampleRate: rate)
        Self.expectCover(bounds, of: samples.count, rate: rate)
        #expect(bounds.count == 2)
        #expect(Double(bounds[1].count) >= Double(rate))
    }

    @Test(arguments: [
        (["今天天气很好。", "我们去公园吧。"], "今天天气很好。我们去公园吧。"),
        (["我们明天去", "公园玩。"], "我们明天去公园玩。"),
        (["Hello there.", "How are you?"], "Hello there. How are you?"),
        (["and then we went to the", "store."], "and then we went to the store."),
        (["我用的是", "iPhone 拍的。"], "我用的是 iPhone 拍的。"),
        (["I use", "微信。"], "I use 微信。"),
        (["好的。", "OK, let's go."], "好的。OK, let's go."),
        (["Fine.", "然后我们走了。"], "Fine. 然后我们走了。"),
        (["the first part", ", and the rest."], "the first part, and the rest."),
        (["他说", "，好的。"], "他说，好的。"),
        (["see the note", "(below)."], "see the note (below)."),
        (["我有5", "个苹果。"], "我有5个苹果。"),
        (["共", "50%的人同意。"], "共50%的人同意。"),
        (["他说“好的”", "然后走了。"], "他说“好的”然后走了。"),
        (["他说", "“好的”。"], "他说“好的”。"),
        (["", "早上好。", "", "晚上好。"], "早上好。晚上好。"),
        (["one"], "one"),
        ([], ""),
    ])
    func textsAreJoinedTheWayTheirLanguageNeeds(_ texts: [String], _ expected: String) {
        #expect(RecordingPieces.joined(texts) == expected)
    }

    /// One piece gives exactly the text a whole recording always did.
    @Test func onePieceIsTheTextOfTheWholeRecording() {
        for raw in [" 你好 ", "這是測試", "", "哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈", "Hello, world."] {
            let transcript = RecordingPieces.transcript(of: [TranscribedPiece(text: raw, seconds: 2)])
            #expect(transcript.text == ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: 2)))
            #expect(transcript.missing == 0)
        }
    }

    /// Each piece is guarded for its own length and kept in simplified characters.
    @Test func eachPieceIsGuardedOnItsOwn() {
        let loop = String(repeating: "好的", count: 40)
        // Too long for a piece of a second, and without a repeat for the loop rule.
        let letters = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 4)
        let transcript = RecordingPieces.transcript(of: [
            TranscribedPiece(text: "這是第一段。", seconds: 50),
            TranscribedPiece(text: loop, seconds: 50),
            TranscribedPiece(text: letters, seconds: 1),
        ])
        #expect(transcript.text == "这是第一段。好的好的 " + String(letters.prefix(60)))
        #expect(transcript.missing == 0)
    }

    /// Only failed pieces are missing. An empty one is quiet, such as a pause to think in a
    /// hands free dictation or the quiet before the key stopped the recording.
    @Test func failedPiecesAreCounted() {
        func missing(_ texts: [String?]) -> Int {
            RecordingPieces.transcript(of: texts.map { TranscribedPiece(text: $0, seconds: 50) }).missing
        }
        #expect(missing(["一。", nil, "三。"]) == 1)
        #expect(missing(["一。", "二。", nil]) == 1)
        #expect(missing([nil, "二。", nil]) == 2)
        #expect(missing(["一。", "", "三。"]) == 0)
        #expect(missing(["一。", "  ", "三。"]) == 0)
        #expect(missing(["一。", "二。", ""]) == 0)
        #expect(missing(["", "", ""]) == 0)
        #expect(missing([""]) == 0)
        let text = RecordingPieces.transcript(of: [TranscribedPiece(text: "一。", seconds: 50), TranscribedPiece(text: nil, seconds: 50), TranscribedPiece(text: "三。", seconds: 50)]).text
        #expect(text == "一。三。")
    }
}
