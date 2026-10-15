import Foundation

/// One stretch of speech the segmenter cut out of the stream, for the speech model.
nonisolated struct CaptionSegment: Equatable, Sendable {
    /// 16 kHz mono samples, the preroll and a short tail of the pause included.
    var samples: [Float]
    /// Where the samples start and end in the stream, in seconds from its first sample.
    var start: Double
    var end: Double

    var duration: Double {
        end - start
    }
}

/// Cuts a stream of 16 kHz mono audio into sentences at pauses, for meeting captions.
///
/// Pure work on values, so it runs on any thread and the tests feed it made up audio. The
/// live captions and the measurement on audio files feed it the same way, see
/// CaptionPipeline.
///
/// Voice activity is the energy of 20 ms frames against two thresholds, with hysteresis:
/// speech starts after a few frames above the higher one and goes on while frames stay
/// above the lower one. Both thresholds follow the noise floor of the pauses, so a call
/// with steady background noise still has pauses. A sentence ends after `pause` without
/// speech. A stretch shorter than `minimumSpeech` is dropped, since a cough or a click
/// gives the model nothing to write and costs a model run. A stretch that reaches
/// `maximumLength` without a pause is cut at the quietest frame of its last
/// `cutWindow`, so the cut falls between words where it can, and the rest starts the next
/// sentence. `preroll` of audio before the start goes with each sentence, since the energy
/// rises a little after the first sound of a word.
nonisolated struct CaptionSegmenter: Sendable {
    nonisolated struct Settings: Equatable, Sendable {
        /// Frames shorter than this are not judged.
        var frameSeconds = 0.02
        /// The RMS a frame needs to count as speech when nothing is heard yet, unless the
        /// noise floor asks for more.
        var startLevel: Float = 0.012
        /// The RMS that keeps speech going once it started. Lower than `startLevel`, so a
        /// soft syllable inside a sentence does not end it.
        var continueLevel: Float = 0.006
        /// How far above the noise floor a frame must be, as a factor of it, to count.
        var startOverFloor: Float = 3
        var continueOverFloor: Float = 2
        /// How many frames in a row above the start level begin speech.
        var startFrames = 3
        /// The silence that ends a sentence.
        var pause = 0.6
        /// The least speech a sentence needs, measured from its start to its last voiced
        /// frame.
        var minimumSpeech = 0.4
        /// The longest sentence before it is cut without a pause.
        var maximumLength = 12.0
        /// Where a long sentence is cut: the quietest frame within this much of its end.
        var cutWindow = 3.0
        /// Audio before the start that goes with the sentence.
        var preroll = 0.2
        /// Audio of the pause after the last voiced frame that goes with the sentence.
        var tail = 0.15
    }

    let settings: Settings
    let sampleRate: Int

    private let frameLength: Int
    /// Samples not yet a whole frame.
    private var pending: [Float] = []
    /// Index in the stream of the first pending sample.
    private var pendingStart = 0
    /// The last frames before speech, for the preroll.
    private var preroll: [Float] = []
    /// The sentence being heard, nil between sentences.
    private var current: Current?
    /// Frames above the start level in a row before speech starts, with their samples.
    private var onset: [Float] = []
    private var onsetFrames = 0
    /// The RMS of the pauses, followed slowly upward and at once downward.
    private(set) var noiseFloor: Float = 0.001

    private struct Current {
        /// Index in the stream of the first sample.
        var start: Int
        var samples: [Float] = []
        /// The RMS of each frame, for the cut of a long sentence.
        var levels: [Float] = []
        /// Frames from the start to the last voiced frame, inclusive.
        var voicedFrames = 0
        /// Frames in a row below the continue level at the end.
        var silentFrames = 0
        /// Frames of preroll at the start, which are not speech.
        var prerollFrames = 0
    }

    init(settings: Settings = Settings(), sampleRate: Int = RecordingLimits.sampleRate) {
        self.settings = settings
        self.sampleRate = sampleRate
        frameLength = max(1, Int((Double(sampleRate) * settings.frameSeconds).rounded()))
    }

    /// True while a sentence is being heard.
    var isInSpeech: Bool {
        current != nil
    }

    /// Takes the next samples of the stream and returns the sentences they finished, in
    /// order.
    mutating func append(_ samples: [Float]) -> [CaptionSegment] {
        pending.append(contentsOf: samples)
        var finished: [CaptionSegment] = []
        var offset = 0
        while pending.count - offset >= frameLength {
            let frame = Array(pending[offset..<(offset + frameLength)])
            if let segment = take(frame, at: pendingStart + offset) {
                finished.append(segment)
            }
            offset += frameLength
        }
        pending.removeFirst(offset)
        pendingStart += offset
        return finished
    }

    /// The end of the stream: the sentence being heard, if it holds enough speech.
    mutating func finish() -> CaptionSegment? {
        defer {
            current = nil
            onset = []
            onsetFrames = 0
            pending = []
        }
        guard var sentence = current else { return nil }
        sentence.samples.append(contentsOf: pending)
        return segment(of: sentence, keepingFrames: sentence.levels.count)
    }

    private func rms(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        return (sum / Float(frame.count)).squareRoot()
    }

    private var startThreshold: Float {
        max(settings.startLevel, noiseFloor * settings.startOverFloor)
    }

    private var continueThreshold: Float {
        max(settings.continueLevel, noiseFloor * settings.continueOverFloor)
    }

    private var pauseFrames: Int {
        Int((settings.pause / settings.frameSeconds).rounded())
    }

    private mutating func take(_ frame: [Float], at index: Int) -> CaptionSegment? {
        let level = rms(frame)
        guard var sentence = current else {
            listen(frame, level: level, at: index)
            return nil
        }
        sentence.samples.append(contentsOf: frame)
        sentence.levels.append(level)
        if level >= continueThreshold {
            sentence.voicedFrames = sentence.levels.count
            sentence.silentFrames = 0
        } else {
            sentence.silentFrames += 1
        }
        if sentence.silentFrames >= pauseFrames {
            current = nil
            return segment(of: sentence, keepingFrames: sentence.voicedFrames + tailFrames)
        }
        if Double(sentence.samples.count) / Double(sampleRate) >= settings.maximumLength {
            return cut(sentence)
        }
        current = sentence
        return nil
    }

    private var tailFrames: Int {
        Int((settings.tail / settings.frameSeconds).rounded())
    }

    /// Between sentences: follows the noise floor, keeps the preroll and starts a sentence
    /// after `startFrames` loud frames in a row.
    private mutating func listen(_ frame: [Float], level: Float, at index: Int) {
        if level >= startThreshold {
            onset.append(contentsOf: frame)
            onsetFrames += 1
            if onsetFrames >= settings.startFrames {
                let prerollSamples = preroll
                var sentence = Current(start: index + frameLength - onset.count - prerollSamples.count)
                sentence.samples = prerollSamples + onset
                let prerollFrames = prerollSamples.count / frameLength
                sentence.prerollFrames = prerollFrames
                // The onset frames were loud. Their levels count as voiced, the preroll's
                // as the floor, so a cut never lands in the preroll.
                sentence.levels = Array(repeating: noiseFloor, count: prerollFrames) + Array(repeating: startThreshold, count: onsetFrames)
                sentence.voicedFrames = sentence.levels.count
                current = sentence
                preroll = []
                onset = []
                onsetFrames = 0
            }
            return
        }
        // A loud frame or two that did not become speech go back to the preroll.
        preroll.append(contentsOf: onset)
        onset = []
        onsetFrames = 0
        preroll.append(contentsOf: frame)
        let keep = Int(settings.preroll * Double(sampleRate)) / frameLength * frameLength
        if preroll.count > keep {
            preroll.removeFirst(preroll.count - keep)
        }
        // Down at once, up slowly, so speech does not lift the floor much.
        noiseFloor = level < noiseFloor ? max(level, 0.0001) : noiseFloor + (level - noiseFloor) * 0.01
    }

    /// The first `frames` frames of a sentence, or nil with too little speech in them.
    private func segment(of sentence: Current, keepingFrames frames: Int) -> CaptionSegment? {
        let speechFrames = sentence.voicedFrames - sentence.prerollFrames
        guard Double(speechFrames) * settings.frameSeconds >= settings.minimumSpeech else { return nil }
        let count = min(sentence.samples.count, frames * frameLength)
        let samples = Array(sentence.samples.prefix(count))
        return CaptionSegment(
            samples: samples,
            start: Double(sentence.start) / Double(sampleRate),
            end: Double(sentence.start + samples.count) / Double(sampleRate)
        )
    }

    /// Cuts a sentence that reached the maximum length at the quietest frame of its last
    /// `cutWindow`, and keeps what follows the cut as the start of the next one.
    private mutating func cut(_ sentence: Current) -> CaptionSegment? {
        let windowFrames = Int((settings.cutWindow / settings.frameSeconds).rounded())
        let windowStart = max(sentence.prerollFrames + 1, sentence.levels.count - windowFrames)
        var quietest = sentence.levels.count - 1
        for frame in windowStart..<sentence.levels.count where sentence.levels[frame] < sentence.levels[quietest] {
            quietest = frame
        }
        // The cut goes after the quietest frame, so it belongs to the first part.
        let cutFrames = quietest + 1
        var rest = Current(start: sentence.start + cutFrames * frameLength)
        rest.samples = Array(sentence.samples.dropFirst(cutFrames * frameLength))
        rest.levels = Array(sentence.levels.dropFirst(cutFrames))
        rest.voicedFrames = rest.levels.lastIndex { $0 >= continueThreshold }.map { $0 + 1 } ?? 0
        rest.silentFrames = rest.levels.count - rest.voicedFrames
        current = rest
        var first = sentence
        first.voicedFrames = min(first.voicedFrames, cutFrames)
        return segment(of: first, keepingFrames: cutFrames)
    }
}
