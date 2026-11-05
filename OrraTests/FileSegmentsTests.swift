import Foundation
import Testing
@testable import Orra

/// Short segments join the one after them when it follows closely, so the speech model
/// hears them with what follows and their subtitles stay up long enough to read.
struct FileSegmentJoinerTests {
    private func segment(_ start: Double, _ end: Double, sample: Float = 0.1) -> CaptionSegment {
        CaptionSegment(samples: [Float](repeating: sample, count: Int(((end - start) * 1_000).rounded())), start: start, end: end)
    }

    @Test func aLongEnoughSegmentPassesAtOnce() {
        var joiner = FileSegmentJoiner()
        #expect(joiner.append(segment(0, 2.5)) == [segment(0, 2.5)])
        #expect(joiner.finish() == nil)
    }

    @Test func aShortSegmentJoinsTheNextOneAcrossAShortPause() {
        var joiner = FileSegmentJoiner()
        let short = segment(1.0, 1.8, sample: 0.1)
        let next = segment(2.5, 6.0, sample: 0.2)
        #expect(joiner.append(short).isEmpty)
        let joined = joiner.append(next)
        #expect(joined.count == 1)
        #expect(joined.first?.start == 1.0)
        #expect(joined.first?.end == 6.0)
        // The samples of both, without the pause between them.
        #expect(joined.first?.samples == short.samples + next.samples)
        #expect(joiner.finish() == nil)
    }

    @Test func shortSegmentsKeepJoiningUntilTheyAreLongEnough() {
        var joiner = FileSegmentJoiner()
        #expect(joiner.append(segment(0, 0.6)).isEmpty)
        #expect(joiner.append(segment(1.0, 1.5)).isEmpty)
        let joined = joiner.append(segment(2.0, 2.6))
        #expect(joined.map(\.start) == [0])
        #expect(joined.map(\.end) == [2.6])
    }

    @Test func aShortSegmentBeforeALongPauseStaysAlone() {
        var joiner = FileSegmentJoiner()
        #expect(joiner.append(segment(1.0, 1.8)).isEmpty)
        #expect(joiner.append(segment(3.0, 6.0)) == [segment(1.0, 1.8), segment(3.0, 6.0)])
    }

    @Test func aJoinNeverMakesASegmentLongerThanFifteenSeconds() {
        var joiner = FileSegmentJoiner()
        #expect(joiner.append(segment(0, 1.5)).isEmpty)
        #expect(joiner.append(segment(2.0, 15.5)) == [segment(0, 1.5), segment(2.0, 15.5)])
    }

    @Test func aShortSegmentAtTheEndComesWithTheFinish() {
        var joiner = FileSegmentJoiner()
        #expect(joiner.append(segment(0, 3)) == [segment(0, 3)])
        #expect(joiner.append(segment(4, 4.9)).isEmpty)
        #expect(joiner.finish() == segment(4, 4.9))
        #expect(joiner.finish() == nil)
    }

    /// The segmenter's settings for files: those of captions, with segments of up to 15 s
    /// cut at the quietest frame after their first 2 s.
    @Test func filesAreCutIntoSegmentsOfAtMostFifteenSeconds() throws {
        let settings = FileSegments.settings
        #expect(settings.maximumLength == 15)
        #expect(settings.cutWindow == 13)
        #expect(settings.pause == CaptionSegmenter.Settings().pause)
        #expect(settings.minimumSpeech == CaptionSegmenter.Settings().minimumSpeech)
        // 38 s of speech without a pause, quieter at 9 s and at 23.5 s.
        let rate = 16_000
        var samples: [Float] = []
        for index in 0..<(38 * rate) {
            let second = Double(index) / Double(rate)
            let quiet = abs(second - 9) < 0.05 || abs(second - 23.5) < 0.05
            samples.append((quiet ? 0.004 : 0.05) * sin(Float(index) * 0.3))
        }
        var segmenter = CaptionSegmenter(settings: settings)
        var segments = segmenter.append([Float](repeating: 0, count: rate / 2) + samples)
        if let last = segmenter.finish() {
            segments.append(last)
        }
        try #require(segments.count == 3)
        #expect(segments.allSatisfy { $0.duration <= 15.01 })
        #expect(segments.dropLast().allSatisfy { $0.duration >= 2 })
        // The cuts land in the quiet moments, half a second later in the stream.
        #expect(abs(segments[0].end - 9.5) < 0.1)
        #expect(abs(segments[1].end - 24.0) < 0.1)
    }
}
