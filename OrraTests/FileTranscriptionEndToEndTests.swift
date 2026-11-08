import AVFoundation
import Foundation
import Testing
@testable import Orra

/// Transcribe File end to end with the real speech model, through the code the window
/// uses: FileAudioSource reads a file, FileTranscription takes each segment's turn and
/// runs the speech model, and FileTranscript writes the subtitles. Skipped wherever
/// RealModelTests are, on CI among them.
///
/// The speech comes from a system voice of this Mac, written into buffers, so nothing
/// plays: five sentences in English and five in Chinese, with known pauses between them.
/// A language whose voice is missing is left out. Each language is written as an .m4a
/// file and as an .mp4 movie with a picture, into a temporary folder the test removes.
/// The test checks the error rate against the spoken text, that a subtitle starts within
/// 1 s of each sentence, and the speed. The numbers are attached as
/// transcribe-file-end-to-end.txt.
///
/// FileTranscriptionMeasurementTests measures a file of 10 minutes of real speech.
extension RealModelTests {
    @Suite(.serialized)
    @MainActor
    struct FileTranscriptionEndToEndTests {
        static let sentences: [(language: String, texts: [String])] = [
            ("en-US", [
                "The quarterly report shows that our sales grew in every region this year.",
                "Please send the final slides to the whole team before Friday afternoon.",
                "We will meet again next week to review the new design together.",
                "The new office has a large kitchen and two quiet rooms for calls.",
                "Our customers asked for a simpler way to share their photos with friends.",
            ]),
            ("zh-CN", [
                "今年每个地区的销售都比去年有明显的增长。",
                "请在周五下午之前把最终的幻灯片发给整个团队。",
                "我们下周再开一次会，一起讨论新的设计方案。",
                "新办公室有一个很大的厨房和两个安静的会议室。",
                "很多客户希望能更简单地和朋友分享照片。",
            ]),
        ]
        /// The pause before the first sentence, between two sentences, and after the last.
        static let pause = 1.5

        @Test func aSpokenFileComesOutAsItsTextWithASubtitleAtEachSentence() async throws {
            let engine = RealModel.engine()
            try await engine.load()
            let folder = try TestMedia.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            var report: [String] = []
            var languages = 0
            for (language, texts) in Self.sentences {
                guard let voice = TestMedia.voice(language) else {
                    report.append("\(language): no system voice on this Mac, left out")
                    continue
                }
                languages += 1
                // The sentences one after another with a pause around each, and where each
                // starts in the file.
                var samples: [Float] = []
                var rate = 0.0
                var starts: [Double] = []
                for text in texts {
                    let spoken = try await TestMedia.speak(text, voice: voice)
                    rate = spoken.rate
                    samples += [Float](repeating: 0, count: Int(Self.pause * rate))
                    starts.append(Double(samples.count) / rate)
                    samples += spoken.samples
                }
                samples += [Float](repeating: 0, count: Int(Self.pause * rate))
                let seconds = Double(samples.count) / rate
                let isChinese = language.hasPrefix("zh")
                for type in ["m4a", "mp4"] {
                    let url = folder.appendingPathComponent("speech \(language).\(type)")
                    if type == "m4a" {
                        try TestMedia.writeAudio(samples, rate: rate, to: url)
                    } else {
                        try await TestMedia.writeMovie(samples, rate: rate, seconds: seconds, video: true, to: url)
                    }
                    let file = FileTranscription(engines: .shared(
                        transcription: .qwen3(engine),
                        turns: EngineTurns(),
                        isSpeechReady: { true },
                        settings: { FileTranscriptionSettings(language: .chinese) },
                        captionsRun: { false }
                    ))
                    let started = ContinuousClock.now
                    file.start(url)
                    try await waitUntil { !file.isRunning }
                    let took = started.duration(to: .now)
                    #expect(file.phase == .finished, "\(language) \(type): \(file.phase)")
                    #expect(file.failedSegments == 0)

                    // The error rate over the whole text, by word for English and by
                    // character for Chinese, without punctuation.
                    let scored = TranscriptScoring.counts(references: [texts.joined(separator: " ")], hypotheses: [file.text.replacingOccurrences(of: "\n", with: " ")], dropFillers: false)
                    let errorRate = 100 * Double(scored.errors) / Double(max(scored.tokens, 1))
                    #expect(errorRate <= 10, "\(language) \(type): \(scored.errors) errors in \(scored.tokens)")

                    // A subtitle starts within a second of each sentence.
                    let cues = Self.cueStarts(of: file.contents(as: .subtitles))
                    for start in starts {
                        #expect(cues.contains { abs($0 - start) <= 1 }, "\(language) \(type): no subtitle near \(start) s, cues at \(cues)")
                    }
                    let nearest = starts.map { start in cues.map { abs($0 - start) }.min() ?? .infinity }

                    // Seconds of work per minute of audio.
                    let perMinute = Self.seconds(took) / (seconds / 60)
                    #expect(perMinute < 15, "\(language) \(type): \(perMinute) s per minute")
                    report.append(String(
                        format: "%@ %@: %.1f s of audio in %.2f s, %.2f s per minute, %ld segments, %ld subtitles, error %.1f%% (%ld of %ld %@), subtitle starts off by at most %.2f s",
                        language, type, seconds, Self.seconds(took), perMinute, file.segments.count, cues.count, errorRate, scored.errors, scored.tokens, isChinese ? "characters" : "words", nearest.max() ?? 0
                    ))
                }
            }
            #expect(languages > 0, "No English or Chinese system voice on this Mac")
            Attachment.record(report.joined(separator: "\n"), named: "transcribe-file-end-to-end.txt")
            print(report.joined(separator: "\n"))
        }

        /// The start of each subtitle of a SubRip text, in seconds.
        static func cueStarts(of subtitles: String) -> [Double] {
            subtitles.split(separator: "\n").compactMap { line -> Double? in
                guard let range = line.range(of: " --> ") else { return nil }
                let parts = line[..<range.lowerBound].split(whereSeparator: { ":,".contains($0) }).compactMap { Double($0) }
                guard parts.count == 4 else { return nil }
                return parts[0] * 3_600 + parts[1] * 60 + parts[2] + parts[3] / 1_000
            }
        }

        static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }
}

/// The speed and accuracy of Transcribe File on 10 minutes of real speech, in English and
/// in Chinese, from the FLEURS clips of the evaluation set joined with pauses of 0.4 to
/// 1.5 s, written as an .m4a file. Compares the error rate with that of the same clips
/// each transcribed whole, and reports the seconds of work per minute of audio and the
/// memory, as transcribe-file-measurement.txt. With TEST_RUNNER_ORRA_TRANSCRIBE_OUT naming a
/// folder outside the repository, it also writes the subtitles and the references there.
/// Only with TEST_RUNNER_ORRA_TRANSCRIBE_MEASURE=1, and best in a Release build:
///
///     TEST_RUNNER_ORRA_TRANSCRIBE_MEASURE=1 xcodebuild test -project Orra.xcodeproj -scheme Orra \
///         -destination 'platform=macOS,arch=arm64' -configuration Release ENABLE_TESTABILITY=YES \
///         -derivedDataPath <folder> -only-testing:OrraTests/RealModelTests/FileTranscriptionMeasurementTests
extension RealModelTests {
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_TRANSCRIBE_MEASURE"] != nil))
    @MainActor
    struct FileTranscriptionMeasurementTests {
        @Test(arguments: ["fleurs_en", "fleurs_zh"])
        func tenMinutesOfSpeech(_ set: String) async throws {
            let engine = RealModel.engine()
            try await engine.load()
            let folder = try TestMedia.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            // Clips in name order until 10 minutes, with pauses between them that repeat.
            let clips = try EvaluationData.clips(in: set, count: 200)
            let pauses = [0.4, 0.8, 1.5, 0.6, 1.1]
            var samples: [Float] = []
            var used: [(name: String, reference: String)] = []
            for (index, clip) in clips.enumerated() where Double(samples.count) < 600 * 16_000 {
                samples += [Float](repeating: 0, count: Int(pauses[index % pauses.count] * 16_000))
                samples += try EvaluationData.samples(set: set, name: clip.name)
                used.append(clip)
            }
            let seconds = Double(samples.count) / 16_000
            let url = folder.appendingPathComponent("\(set).m4a")
            try TestMedia.writeAudio(samples, rate: 16_000, to: url)
            samples = []

            let before = MemoryFootprint.current()
            let file = FileTranscription(engines: .shared(
                transcription: .qwen3(engine),
                turns: EngineTurns(),
                isSpeechReady: { true },
                settings: { FileTranscriptionSettings(language: .chinese) },
                captionsRun: { false }
            ))
            let started = ContinuousClock.now
            file.start(url)
            var peak = before
            while file.isRunning {
                try await Task.sleep(for: .milliseconds(200))
                peak = max(peak, MemoryFootprint.current())
            }
            let took = FileTranscriptionEndToEndTests.seconds(started.duration(to: .now))
            #expect(file.phase == .finished)

            // The file's text against the references joined, and the same clips each
            // transcribed whole, from the baseline of the evaluation set.
            let references = used.map(\.reference).joined(separator: " ")
            let ours = TranscriptScoring.counts(references: [references], hypotheses: [file.text.replacingOccurrences(of: "\n", with: " ")], dropFillers: false)
            let baseline = try EvaluationData.baseline(engine: "q17_auto", set: set)
            let whole = TranscriptScoring.counts(references: used.map(\.reference), hypotheses: used.map { baseline[$0.name] ?? "" }, dropFillers: false)
            let lengths = file.segments.map { $0.end - $0.start }.sorted()
            let report = String(
                format: "%@: %ld clips, %.1f min of audio in %.1f s, %.2f s per minute; %ld segments, median %.1f s, shortest %.1f s, longest %.1f s; error %.2f%% (%ld of %ld) against %.2f%% for the clips whole; memory %ld MB before, %ld MB more at the peak",
                set, used.count, seconds / 60, took, took / (seconds / 60), file.segments.count, lengths.isEmpty ? 0 : lengths[lengths.count / 2], lengths.first ?? 0, lengths.last ?? 0,
                100 * Double(ours.errors) / Double(max(ours.tokens, 1)), ours.errors, ours.tokens, 100 * Double(whole.errors) / Double(max(whole.tokens, 1)),
                Int(before / 1_000_000), Int((Int64(peak) - Int64(before)) / 1_000_000)
            )
            Attachment.record(report, named: "transcribe-file-measurement-\(set).txt")
            // The subtitles and the references, for a look at what went wrong, into a folder
            // outside the repository. The text is that of the public clips.
            if let out = ProcessInfo.processInfo.environment["ORRA_TRANSCRIBE_OUT"] {
                let folder = URL(fileURLWithPath: out, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try file.contents(as: .subtitles).write(to: folder.appendingPathComponent("\(set).srt"), atomically: true, encoding: .utf8)
                try used.map { "\($0.name)\t\($0.reference)" }.joined(separator: "\n").write(to: folder.appendingPathComponent("\(set).refs.tsv"), atomically: true, encoding: .utf8)
            }
        }
    }
}
