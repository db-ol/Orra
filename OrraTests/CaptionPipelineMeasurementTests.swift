import AVFoundation
import Foundation
import Testing
@testable import Orra

/// Runs meeting captions on audio files with the real models, through CaptionPipeline and
/// the same engines the app builds, see CaptionEngines.shared. Only when asked for, with
/// TEST_RUNNER_ORRA_CAPTION_EVAL=1, and only when the speech model is on this Mac. It
/// loads both models, about 5 GB, so run it on its own, in a Release build:
///
///     TEST_RUNNER_ORRA_CAPTION_EVAL=1 \
///     TEST_RUNNER_ORRA_CAPTION_AUDIO=<file or folder> \
///     TEST_RUNNER_ORRA_CAPTION_OUT=<file.jsonl outside the repository> \
///     xcodebuild test -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' \
///         -configuration Release ENABLE_TESTABILITY=YES -derivedDataPath <folder> \
///         -only-testing:OrraTests/CaptionPipelineMeasurementTests
///
/// The audio is every .wav, .m4a, .mp3, .caf, .aif and .flac file in the folder, in name
/// order, or the one file. Each is read whole, mixed to mono and resampled to 16 kHz, then
/// fed in chunks of 100 ms, as the capture feeds it. Optional variables, each with the
/// TEST_RUNNER_ prefix:
///
/// - ORRA_CAPTION_SETTINGS: a JSON object that changes CaptionSegmenter.Settings, such as
///   {"pause": 0.5, "startLevel": 0.01}, for tuning.
/// - ORRA_CAPTION_TARGET: the caption target, zh (the default) or en, see TranslationTarget.
/// - ORRA_CAPTION_TRANSLATE=0: transcripts only, without loading the cleanup model.
/// - ORRA_CAPTION_REALTIME=1: feeds the audio at the pace it plays, so the latency of each
///   caption is measured as the live captions would see it.
/// - ORRA_CAPTION_INTERIM: seconds between interim texts of a sentence still being heard,
///   see CaptionPipeline.interimInterval. Off when unset or 0. Only useful in real time.
/// - ORRA_REWRITE_MODEL_DIR: the cleanup model, see RewriteTestModel.
///
/// The output file gets one JSON object per sentence: the file, the sentence's start and
/// end in seconds, the transcript, the translation or null, the model times, and with
/// ORRA_CAPTION_REALTIME the latency from the end of the sentence in the audio to its
/// caption and to its translation, and when the first text of it showed, interim or
/// final, in seconds from the start of the file, with the number of interim texts. A
/// summary of counts and times, never text, goes to a
/// file next to it, with the extension summary.txt. The output holds the text of the
/// audio, so point it at public audio only, and outside the repository.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORRA_CAPTION_EVAL"] != nil && RealModel.folder != nil))
@MainActor
struct CaptionPipelineMeasurementTests {
    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    @Test func captionTheAudioFiles() async throws {
        let audio = try #require(Self.environment["ORRA_CAPTION_AUDIO"], "Set TEST_RUNNER_ORRA_CAPTION_AUDIO to a file or folder")
        let outputPath = try #require(Self.environment["ORRA_CAPTION_OUT"], "Set TEST_RUNNER_ORRA_CAPTION_OUT to a .jsonl file")
        let files = try Self.audioFiles(at: URL(fileURLWithPath: audio))
        try #require(!files.isEmpty, "No audio files")
        let settings = try Self.settings()
        let target = Self.environment["ORRA_CAPTION_TARGET"].flatMap(TranslationTarget.init(rawValue:)) ?? .chinese
        let realtime = Self.environment["ORRA_CAPTION_REALTIME"] == "1"
        let translates = Self.environment["ORRA_CAPTION_TRANSLATE"] != "0"
        let interimInterval = Self.environment["ORRA_CAPTION_INTERIM"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }

        let speech = RealModel.engine()
        try await speech.load()
        let rewrite = RewriteEngine()
        if translates {
            let folder = try #require(RewriteTestModel.folder, "The cleanup model is not on this Mac. Set TEST_RUNNER_ORRA_CAPTION_TRANSLATE=0 or TEST_RUNNER_ORRA_REWRITE_MODEL_DIR")
            try await rewrite.load(from: folder)
            try await rewrite.prepareTranslation(into: CaptionTarget.route(target, in: .chinese))
        }
        var engines = CaptionEngines.shared(
            transcription: .qwen3(speech),
            isSpeechReady: { true },
            canTranslate: { translates },
            target: { target },
            complete: { try await rewrite.translate($0, into: $1).answer },
            turns: EngineTurns()
        )
        // Counts the model calls, for the cost.
        var calls = (final: 0, interim: 0, translation: 0)
        let transcribe = engines.transcribe
        let transcribeInterim = engines.transcribeInterim ?? transcribe
        let translate = engines.translate
        engines.transcribe = { samples, language in
            calls.final += 1
            return try await transcribe(samples, language)
        }
        engines.transcribeInterim = { samples, language in
            calls.interim += 1
            return try await transcribeInterim(samples, language)
        }
        engines.translate = { text, route in
            calls.translation += 1
            return try await translate(text, route)
        }

        let output = URL(fileURLWithPath: outputPath)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var sentences = 0
        var translated = 0
        var recognition: [Double] = []
        var translation: [Double] = []
        var captionLatency: [Double] = []
        var translationLatency: [Double] = []
        var firstTextLatency: [Double] = []
        var audioSeconds = 0.0
        let started = ContinuousClock.now

        for file in files {
            let samples = try Self.samples(of: file)
            audioSeconds += Double(samples.count) / Double(RecordingLimits.sampleRate)
            var fedAt = ContinuousClock.now
            var lines: [Int: [String: Any]] = [:]
            var order: [Int] = []
            // Faster than real time every sentence waits, so none may skip its translation.
            let pipeline = CaptionPipeline(engines: engines, settings: settings, backlogLimit: realtime ? CaptionPipeline.defaultBacklogLimit : .max, interimInterval: interimInterval, withdraw: { id in
                lines[id] = nil
                order.removeAll { $0 == id }
            }) { sentence in
                // Seconds since the start of the file and since the end of the sentence was
                // fed, as the live captions would see it, in real time only.
                let now = fedAt.duration(to: .now) / .seconds(1)
                let sinceEnd = now - sentence.end
                var line = lines[sentence.id] ?? ["file": file.lastPathComponent, "id": sentence.id, "interim_count": 0]
                if lines[sentence.id] == nil {
                    order.append(sentence.id)
                    if realtime {
                        line["first_text_at_s"] = now
                    }
                }
                if sentence.isInterim {
                    line["interim_count"] = (line["interim_count"] as? Int ?? 0) + 1
                    lines[sentence.id] = line
                    return
                }
                if line["original"] == nil {
                    line["start"] = sentence.start
                    line["end"] = sentence.end
                    line["original"] = sentence.original
                    line["recognition_s"] = sentence.recognitionSeconds
                    if realtime {
                        line["caption_latency_s"] = sinceEnd
                    }
                }
                switch sentence.translation {
                case .done(let text):
                    line["translation"] = text
                    line["translation_s"] = sentence.translationSeconds
                    if realtime {
                        line["translation_latency_s"] = sinceEnd
                    }
                case .none:
                    line["translation"] = NSNull()
                    if sentence.translationSeconds > 0 {
                        line["translation_s"] = sentence.translationSeconds
                    }
                case .pending:
                    break
                }
                lines[sentence.id] = line
            }
            let chunk = RecordingLimits.sampleRate / 10
            fedAt = .now
            var index = 0
            while index < samples.count {
                let end = min(samples.count, index + chunk)
                pipeline.feed(Array(samples[index..<end]))
                index = end
                if realtime {
                    try await Task.sleep(until: fedAt + .seconds(Double(index) / Double(RecordingLimits.sampleRate)))
                } else {
                    // Waits for the sentences cut so far, so none is dropped from a full
                    // queue, see CaptionPipeline.waitingLimit.
                    while pipeline.waitingSentences > 0 {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
            }
            await pipeline.finish()
            for id in order {
                guard let line = lines[id], line["original"] != nil else { continue }
                sentences += 1
                if line["translation"] is String {
                    translated += 1
                }
                recognition.append(line["recognition_s"] as? Double ?? 0)
                if let seconds = line["translation_s"] as? Double {
                    translation.append(seconds)
                }
                if let seconds = line["caption_latency_s"] as? Double {
                    captionLatency.append(seconds)
                }
                if let seconds = line["translation_latency_s"] as? Double {
                    translationLatency.append(seconds)
                }
                if let at = line["first_text_at_s"] as? Double, let start = line["start"] as? Double {
                    firstTextLatency.append(at - start)
                }
                var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
                data.append(0x0A)
                try handle.write(contentsOf: data)
            }
        }

        let summary = """
        Caption measurement: \(files.count) files, \(String(format: "%.1f", audioSeconds)) s of audio, \(sentences) sentences, \(translated) translated, \
        took \(started.duration(to: .now)), realtime: \(realtime), settings: \(settings)
        Recognition per sentence: \(Self.summary(recognition))
        Translation per sentence: \(Self.summary(translation))
        Caption latency: \(Self.summary(captionLatency))
        Translation latency: \(Self.summary(translationLatency))
        First text from the sentence start: \(Self.summary(firstTextLatency)), interim interval: \(interimInterval.map { "\($0) s" } ?? "off")
        Model calls: \(calls.final) final, \(calls.interim) interim, \(calls.translation) translations, \(String(format: "%.1f", Double(calls.final + calls.interim) / audioSeconds * 60)) speech model calls per minute of audio

        """
        print(summary)
        // Next to the output, since xcodebuild does not show what a test prints.
        try summary.write(to: output.deletingPathExtension().appendingPathExtension("summary.txt"), atomically: true, encoding: .utf8)
        await rewrite.unload()
    }

    /// Median, 90th percentile and maximum, in seconds.
    private static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        func at(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
        }
        return String(format: "median %.2f s, p90 %.2f s, max %.2f s, n %d", at(0.5), at(0.9), sorted.last!, sorted.count)
    }

    private static func audioFiles(at url: URL) throws -> [URL] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return [] }
        guard isFolder.boolValue else { return [url] }
        let extensions: Set<String> = ["wav", "m4a", "mp3", "caf", "aif", "aiff", "flac"]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The segmenter settings with what ORRA_CAPTION_SETTINGS changes.
    private static func settings() throws -> CaptionSegmenter.Settings {
        var settings = CaptionSegmenter.Settings()
        guard let json = environment["ORRA_CAPTION_SETTINGS"], !json.isEmpty else { return settings }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        for (key, value) in object {
            switch key {
            case "startLevel": settings.startLevel = Float(value)
            case "continueLevel": settings.continueLevel = Float(value)
            case "startOverFloor": settings.startOverFloor = Float(value)
            case "continueOverFloor": settings.continueOverFloor = Float(value)
            case "startFrames": settings.startFrames = Int(value)
            case "pause": settings.pause = value
            case "minimumSpeech": settings.minimumSpeech = value
            case "maximumLength": settings.maximumLength = value
            case "cutWindow": settings.cutWindow = value
            case "preroll": settings.preroll = value
            case "tail": settings.tail = value
            default: Issue.record("Unknown segmenter setting \(key)")
            }
        }
        return settings
    }

    /// The file mixed to mono and resampled to 16 kHz, read in blocks.
    static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RecordingLimits.sampleRate), channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        converter.downmix = true
        let block: AVAudioFrameCount = 65_536
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * output.sampleRate / input.sampleRate) + 1_024)
        var finished = false
        let converted = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(block) * output.sampleRate / input.sampleRate) + 1_024))
        while true {
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: block),
                      (try? file.read(into: buffer, frameCount: block)) != nil, buffer.frameLength > 0 else {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                throw error ?? CocoaError(.fileReadCorruptFile)
            }
            if let channel = converted.floatChannelData?[0], converted.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
            if status == .endOfStream {
                break
            }
        }
        return samples
    }
}
