import AVFoundation

/// Where the text shown while the user speaks cuts the recording, see LiveDictation.
///
/// CaptionSegmenter finds the sentences at pauses, with the settings it has for captions,
/// and each piece runs from the cut before it to the end of its sentence, so the pieces
/// cover the recording without a gap. What the segmenter leaves out, such as a pause, a
/// cough or a word with less than `minimumSpeech`, stays in the piece that follows. A
/// sentence that reaches `maximumLength` without a pause is cut at its quietest frame, as
/// for captions. Pure work on values, so the tests feed it made up audio.
nonisolated struct DictationPieces: Sendable {
    /// One piece that the end of a sentence finished.
    nonisolated struct Piece: Equatable, Sendable {
        /// From the cut before it to the end of its sentence, in samples of the stream.
        var range: Range<Int>
        /// The sentence alone, its preroll and tail included.
        var sentence: Range<Int>
    }

    /// The segmenter's settings for dictation: those of captions, see CaptionSegmenter.
    static let settings = CaptionSegmenter.Settings()

    let settings: CaptionSegmenter.Settings
    let sampleRate: Int
    private var segmenter: CaptionSegmenter
    /// Samples taken in so far.
    private(set) var count = 0
    /// Where the latest piece ends, 0 before the first.
    private(set) var lastCut = 0

    init(settings: CaptionSegmenter.Settings = DictationPieces.settings, sampleRate: Int = RecordingLimits.sampleRate) {
        self.settings = settings
        self.sampleRate = sampleRate
        segmenter = CaptionSegmenter(settings: settings, sampleRate: sampleRate)
    }

    /// Takes the next samples and returns the pieces they finished, in order.
    mutating func append(_ samples: [Float]) -> [Piece] {
        let sentences = segmenter.append(samples)
        count += samples.count
        return sentences.map { sentence in
            let start = index(of: sentence.start)
            let end = start + sentence.samples.count
            // Sentences never overlap, so the cut only moves on.
            let piece = Piece(range: lastCut..<max(end, lastCut), sentence: start..<end)
            lastCut = max(end, lastCut)
            return piece
        }
    }

    /// True while a sentence is being heard.
    var isInSpeech: Bool {
        segmenter.isInSpeech
    }

    /// Seconds of the sentence being heard, its preroll included, 0 between sentences.
    var openSeconds: Double {
        segmenter.openSeconds
    }

    /// Seconds since the last voiced frame of the sentence being heard, 0 between them.
    var openSilenceSeconds: Double {
        segmenter.openSilenceSeconds
    }

    /// The sentence being heard, up to its last voiced frame and a tail, in samples of the
    /// stream. Nil between sentences and while it holds less than `minimumSpeech`.
    var openSentence: Range<Int>? {
        segmenter.openSentence.map { sentence in
            let start = index(of: sentence.start)
            return start..<(start + sentence.samples.count)
        }
    }

    /// The audio a pass for the text on screen reads for `sentence`: from `leadIn` seconds
    /// before it, so a short word just before the sentence that the segmenter left out
    /// shows too, though never from before `cut`, to the end of the sentence, and at most
    /// `maximumLength` and the preroll long, so a pass never grows with a long pause.
    func shownRange(for sentence: Range<Int>, after cut: Int, leadIn: Double) -> Range<Int> {
        let rate = Double(sampleRate)
        let longest = Int(((settings.maximumLength + settings.preroll) * rate).rounded())
        let start = max(cut, sentence.lowerBound - Int((leadIn * rate).rounded()), sentence.upperBound - longest)
        return min(start, sentence.upperBound)..<sentence.upperBound
    }

    /// The index in the stream of a time the segmenter gave, which it computed from that
    /// index.
    private func index(of seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }
}

/// Converts the recording of a hold to 16 kHz while it records, a little at a time, with
/// one converter for the whole hold. So the samples are those one conversion of the whole
/// recording gives, as AudioResampler does after the release, but for the end, which the
/// converter holds back until more comes, 47 ms from 48 kHz in a test on macOS 27.2.
/// Not Sendable: one actor owns it, see LiveAudio.
nonisolated final class LiveResampler {
    /// The rate it converts from.
    let sampleRate: Double
    private let converter: AVAudioConverter?
    private let input: AVAudioFormat?
    private let output: AVAudioFormat?

    /// Nil for a rate the converter does not take. 16 kHz goes through as it is.
    init?(sampleRate: Double) {
        let target = Double(RecordingLimits.sampleRate)
        self.sampleRate = sampleRate
        guard sampleRate > 0 else { return nil }
        guard sampleRate != target else {
            converter = nil
            input = nil
            output = nil
            return
        }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// The next samples at 16 kHz, from the next samples at `sampleRate`.
    func convert(_ samples: [Float]) -> [Float] {
        guard let converter, let input, let output else { return samples }
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return [] }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        // Room for these samples and for what the converter held back from the ones before.
        let expected = (Double(samples.count) * output.sampleRate / sampleRate).rounded(.up)
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(expected) + 1_024) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                // More comes with the next read, so the converter keeps its state.
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let result = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: result, count: Int(converted.frameLength)))
    }
}
