import Foundation
import Observation

nonisolated enum VoiceSampleCaptureError: Error, Equatable {
    /// A dictation runs, the microphone has no access, or a voice sample is being recorded.
    case busy
}

/// The text the user reads aloud for a voice sample. Everyday words with no names, about
/// 10 seconds at a calm pace, which fits VoiceSample.maximumSeconds. Each script is in its
/// own language whatever language Orra shows, so it is not localized.
nonisolated enum VoiceScript {
    /// The language the user speaks in meetings: the source of a fixed translation
    /// direction, and for the automatic one the language Orra shows.
    static func language(direction: TranslationDirection, interface: Locale = .interface) -> TranslationTarget {
        switch direction {
        case .english: .chinese
        case .chinese: .english
        case .automatic: interface.language.languageCode == .chinese ? .chinese : .english
        }
    }

    static func text(in language: TranslationTarget) -> String {
        switch language {
        case .english:
            "This morning the weather was clear, so I walked to the market. I bought apples, fresh bread and some coffee, and then I read by the window for a while."
        case .chinese:
            "今天早上天气很好，我走路去了市场。买了一些苹果、新鲜的面包和咖啡，然后坐在窗边看了一会儿书。"
        }
    }

    /// The name of a script's language in that language, for the picker.
    static func name(of language: TranslationTarget) -> String {
        switch language {
        case .english: "English"
        case .chinese: "中文"
        }
    }
}

/// What VoiceRecording needs from the microphone. Closures, so tests pass fakes and never
/// touch a microphone. The app's go through PushToTalkController and AudioRecorder, the
/// same path as a dictation, which records into memory only.
struct VoiceRecorder {
    var start: () async throws -> Void
    var stop: () async -> AudioRecording
    var cancel: () async -> Void
    /// The peak of the latest audio while recording, from 0 to 1.
    var level: () -> Float = { 0 }

    static func live(_ pushToTalk: PushToTalkController) -> VoiceRecorder {
        VoiceRecorder(
            start: { try await pushToTalk.startVoiceSample() },
            stop: { await pushToTalk.stopVoiceSample() },
            cancel: { await pushToTalk.cancelVoiceSample() },
            level: { pushToTalk.inputLevel() }
        )
    }
}

/// Records a voice sample in Settings: the user reads a script aloud, listens to it, and
/// uses it or records again. The recording stays in memory, and is dropped when the sheet
/// closes without being used. Nothing is logged but lengths.
@Observable
final class VoiceRecording: Identifiable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        /// The microphone is starting.
        case starting
        case recording
        /// The microphone is stopping.
        case stopping
        /// A sample is ready to play back or use.
        case recorded
        /// Shorter than VoiceSample.minimumSeconds.
        case tooShort
        /// Says why there is no sample.
        case failed(String)
    }

    /// A recording stops by itself after this long. Only the first
    /// VoiceSample.maximumSeconds are kept, the rest gives a slow reader room.
    static let maximumSeconds = 20.0

    private(set) var phase = Phase.idle
    /// Seconds since the recording started, while it runs, and the length after.
    private(set) var elapsed = 0.0
    /// The meter, from 0 to 1, falling slowly after a peak as the recording indicator's.
    private(set) var level = 0.0
    /// True when the recording stopped at `maximumSeconds`.
    private(set) var stoppedAtLimit = false
    private(set) var isPlaying = false
    /// The script's language, which the user can change.
    var scriptLanguage: TranslationTarget
    /// The sample once recorded, held in memory only.
    private(set) var sample: VoiceSample?

    @ObservationIgnored private let recorder: VoiceRecorder
    @ObservationIgnored private let playback: any SpeechPlayback
    @ObservationIgnored private let output: () -> AudioOutput?
    @ObservationIgnored private let maximum: Duration
    @ObservationIgnored private let tick: Duration
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var started: ContinuousClock.Instant?
    /// Counts the starts and cancels, so a start that ends after a cancel stops the
    /// microphone again and changes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playGeneration = 0

    /// - Parameters:
    ///   - recorder: The microphone. Tests pass fakes.
    ///   - playback: Plays the sample back. Tests pass fakes.
    ///   - output: The device the sample plays back on, the system's default output.
    ///   - scriptLanguage: The language of the script shown first.
    ///   - maximum: How long a recording may run. Tests pass a short one.
    ///   - tick: How often the time and the meter update.
    init(
        recorder: VoiceRecorder,
        playback: any SpeechPlayback,
        output: @escaping () -> AudioOutput?,
        scriptLanguage: TranslationTarget,
        maximum: Duration = .seconds(VoiceRecording.maximumSeconds),
        tick: Duration = .milliseconds(33)
    ) {
        self.recorder = recorder
        self.playback = playback
        self.output = output
        self.scriptLanguage = scriptLanguage
        self.maximum = maximum
        self.tick = tick
    }

    var script: String {
        VoiceScript.text(in: scriptLanguage)
    }

    var isRecording: Bool {
        phase == .starting || phase == .recording || phase == .stopping
    }

    /// Starts a recording, in place of any before it.
    func start() {
        guard !isRecording else { return }
        stopPlaying()
        generation += 1
        let generation = generation
        sample = nil
        elapsed = 0
        level = 0
        stoppedAtLimit = false
        phase = .starting
        Task {
            do {
                try await recorder.start()
            } catch {
                guard generation == self.generation else { return }
                phase = .failed(String(localized: "The microphone could not start"))
                return
            }
            guard generation == self.generation else {
                await recorder.cancel()
                return
            }
            phase = .recording
            started = .now
            runTicker(generation)
        }
    }

    /// Stops the recording and keeps it when it is long enough.
    func stop() {
        guard phase == .recording else { return }
        finish(atLimit: false)
    }

    /// Stops any recording or playback and drops the sample. For Cancel and the sheet
    /// closing.
    func cancel() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        stopPlaying()
        let wasRecording = phase == .recording
        phase = .idle
        sample = nil
        elapsed = 0
        level = 0
        if wasRecording {
            Task { await recorder.cancel() }
        }
    }

    /// Hands the sample over once, and forgets it here.
    func take() -> VoiceSample? {
        guard phase == .recorded, let sample else { return nil }
        stopPlaying()
        self.sample = nil
        phase = .idle
        return sample
    }

    /// Plays the sample on the default output, or stops it while it plays.
    func togglePlayback() {
        if isPlaying {
            stopPlaying()
            return
        }
        guard phase == .recorded, let sample, let device = output() else { return }
        do {
            try playback.start(on: device)
        } catch {
            return
        }
        playGeneration += 1
        let current = playGeneration
        isPlaying = true
        playback.play(SpokenAudio(samples: sample.samples, sampleRate: sample.sampleRate))
        Task {
            await playback.finish()
            guard current == playGeneration else { return }
            playback.stop()
            isPlaying = false
        }
    }

    var canPlayBack: Bool {
        phase == .recorded && output() != nil
    }

    private func stopPlaying() {
        guard isPlaying else { return }
        playGeneration += 1
        playback.stop()
        isPlaying = false
    }

    private func runTicker(_ generation: Int) {
        ticker?.cancel()
        ticker = Task { [tick, maximum] in
            while !Task.isCancelled, generation == self.generation, phase == .recording, let started {
                let now = started.duration(to: .now)
                elapsed = Self.seconds(now)
                let target = RecordingFeedback.meterLevel(peak: recorder.level())
                level = target >= level ? target : max(target, level * 0.85)
                if now >= maximum {
                    finish(atLimit: true)
                    return
                }
                try? await Task.sleep(for: tick)
            }
        }
    }

    private func finish(atLimit: Bool) {
        ticker?.cancel()
        ticker = nil
        phase = .stopping
        level = 0
        let generation = generation
        Task {
            let recording = await recorder.stop()
            guard generation == self.generation else { return }
            elapsed = recording.duration
            stoppedAtLimit = atLimit
            phase = Self.judge(recording)
            if phase == .recorded {
                sample = VoiceSample(recorded: recording.samples, sampleRate: Int(recording.sampleRate.rounded()))
            }
        }
    }

    /// What a finished recording comes to. Internal for tests.
    static func judge(_ recording: AudioRecording) -> Phase {
        if recording.wasCut {
            return .failed(String(localized: "The microphone changed during the recording. Try again."))
        }
        if recording.duration < VoiceSample.minimumSeconds {
            return .tooShort
        }
        if Silence.isSilent(recording.samples) {
            return .failed(String(localized: "No sound came from the microphone"))
        }
        return .recorded
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
