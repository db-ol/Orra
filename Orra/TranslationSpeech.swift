import Foundation
import Observation
import os

/// What PushToTalkController needs to speak a translation. Closures, so tests pass fakes.
struct TranslationVoice {
    /// Whether a translation is spoken: Speak Translation is on and this build can speak.
    var speaks: () -> Bool
    /// Whether a spoken translation is pasted too.
    var alsoPastes: () -> Bool
    /// Queues a translation to be spoken, and returns at once.
    var speak: (String, TranslationTarget) -> Void

    static let off = TranslationVoice(speaks: { false }, alsoPastes: { true }, speak: { _, _ in })
}

/// Speak Translation: speaks what the translation key translated, in a voice model, into
/// an output device such as Orra's own microphone device, so the other side of a call
/// hears it. Optionally in the voice of a sample the user chose, which stays in memory
/// only. Translations are spoken one after another in the order they came. Dictation
/// comes first: a piece waits to be synthesized while the user dictates, so the speech
/// and cleanup models are not kept waiting for the GPU by the voice. No text and no audio
/// is logged or saved.
@Observable
final class TranslationSpeech {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case loading
        case speaking
    }

    private(set) var isOn: Bool
    private(set) var alsoPastes: Bool
    /// The output the user chose, nil for Orra's own microphone device when it is there.
    private(set) var output: SpeechOutputChoice?
    private(set) var state = State.idle
    /// Why the last translation was not spoken, for Settings and the menu. Cleared when a
    /// translation is spoken or a setting changes.
    private(set) var problem: String?
    /// The length of the voice sample in memory, nil without one.
    private(set) var voiceSeconds: Double?
    /// The speech model is writing down what is said in a voice sample the user picked.
    private(set) var isListeningToVoice = false
    /// The model is loaded.
    private(set) var isLoaded = false
    /// The voice model that speaks, nil in a build without one.
    private(set) var engine: VoiceEngineKind?

    /// True when this build has a voice model, see VoiceEngines.
    var canSpeak: Bool {
        engine != nil && synthesizer != nil
    }

    /// The voice models Settings offers, empty unless the build has more than one.
    var engineChoices: [VoiceEngineKind] {
        engines.offersChoice ? engines.available : []
    }

    /// Whether PushToTalkController hands translations over.
    var speaks: Bool {
        isOn && canSpeak
    }

    /// Whether a dictation is under way, which the voice waits for. AppDelegate sets it.
    @ObservationIgnored var isDictating: () -> Bool = { false }
    /// Writes down what is said in a voice sample, with the speech model of dictation. The
    /// voice model needs the words to imitate the voice. AppDelegate sets it, tests pass
    /// fakes.
    @ObservationIgnored var transcribeVoice: (VoiceSample) async throws -> String = { _ in throw TranscriptionError.modelMissing }
    /// Called after the user picked another voice model, so its downloads take the place of
    /// the old one's. AppDelegate sets it.
    @ObservationIgnored var onEngineChange: (VoiceEngineKind) -> Void = { _ in }

    @ObservationIgnored private var voice: VoiceSample?
    @ObservationIgnored private let engines: VoiceEngines
    /// The model the user picked, nil until they pick one, so a build that has both
    /// starts with VoiceEngineChoice.preferred.
    @ObservationIgnored private var chosenEngine: VoiceEngineKind?
    @ObservationIgnored private var synthesizer: (any SpeechSynthesizer)?
    /// Counts the changes of voice model, so a load of the old model that ends after a
    /// change does not count as a load of the new one.
    @ObservationIgnored private var synthesizerRevision = 0
    @ObservationIgnored private let playback: any SpeechPlayback
    @ObservationIgnored private let outputs: () -> [AudioOutput]
    @ObservationIgnored private let folders: () -> VoiceModelFolders?
    @ObservationIgnored private let save: (Settings) -> Void
    @ObservationIgnored private let dictationPoll: Duration
    /// Counts the voice samples picked and removed, so a sample that is still being
    /// written down when another is picked or Remove is clicked is dropped.
    @ObservationIgnored private var voiceRequest = 0
    /// The translations queued and being spoken, one after another.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Counts the stops, so queued work of an older generation does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.db-ol.Orra", category: "speech")

    /// The saved settings. Never the voice sample.
    nonisolated struct Settings: Equatable, Sendable {
        var isOn = false
        var alsoPastes = true
        var output: SpeechOutputChoice?
        /// The voice model the user picked, nil until they pick one.
        var voiceModel: VoiceEngineKind?

        static func load(from defaults: UserDefaults = .standard) -> Settings {
            Settings(
                isOn: SpeechPreference.isOn(in: defaults),
                alsoPastes: SpeechPreference.alsoPastes(in: defaults),
                output: SpeechPreference.output(in: defaults),
                voiceModel: SpeechPreference.voiceModel(in: defaults)
            )
        }

        func save(to defaults: UserDefaults = .standard) {
            SpeechPreference.saveIsOn(isOn, to: defaults)
            SpeechPreference.saveAlsoPastes(alsoPastes, to: defaults)
            SpeechPreference.saveOutput(output, to: defaults)
            SpeechPreference.saveVoiceModel(voiceModel, to: defaults)
        }
    }

    /// - Parameters:
    ///   - engines: The voice models of this build. Tests pass fakes.
    ///   - playback: Plays into the output. Tests pass fakes.
    ///   - outputs: The output devices connected now. Tests pass fakes.
    ///   - folders: The voice model's folders once both are installed, nil before.
    ///   - settings: As saved.
    ///   - save: Saves the settings after they change.
    ///   - dictationPoll: How often a waiting piece checks whether the dictation ended.
    init(
        engines: VoiceEngines,
        playback: any SpeechPlayback,
        outputs: @escaping () -> [AudioOutput],
        folders: @escaping () -> VoiceModelFolders?,
        settings: Settings = Settings(),
        save: @escaping (Settings) -> Void = { _ in },
        dictationPoll: Duration = .milliseconds(50)
    ) {
        self.engines = engines
        let engine = VoiceEngineChoice.resolve(saved: settings.voiceModel, available: engines.available)
        self.engine = engine
        self.chosenEngine = settings.voiceModel
        self.synthesizer = engine.flatMap(engines.make)
        self.playback = playback
        self.outputs = outputs
        self.folders = folders
        self.isOn = settings.isOn
        self.alsoPastes = settings.alsoPastes
        self.output = settings.output
        self.save = save
        self.dictationPoll = dictationPoll
    }

    /// For PushToTalkController. A translation is pasted even with Also Paste off while
    /// the voice model is not on this Mac or no device would take the voice, so it is not
    /// lost to a translation that cannot be spoken.
    var voiceForDictation: TranslationVoice {
        TranslationVoice(
            speaks: { [weak self] in self?.speaks == true },
            alsoPastes: { [weak self] in
                guard let self else { return true }
                return self.alsoPastes || self.folders() == nil || self.currentDevice() == nil
            },
            speak: { [weak self] text, language in self?.speak(text, in: language) }
        )
    }

    private var settings: Settings {
        Settings(isOn: isOn, alsoPastes: alsoPastes, output: output, voiceModel: chosenEngine)
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        problem = nil
        save(settings)
        if on {
            prepare()
        } else {
            stop()
            unload()
        }
    }

    func setAlsoPastes(_ on: Bool) {
        guard on != alsoPastes else { return }
        alsoPastes = on
        save(settings)
    }

    func setOutput(_ choice: SpeechOutputChoice?) {
        guard choice != output else { return }
        output = choice
        problem = nil
        save(settings)
    }

    /// Voice model in Settings. Stops what is playing, unloads the old model after the piece
    /// it may still be making, and keeps the voice sample and what is said in it, which the
    /// new model reads too. The new model loads once its downloads are in place.
    func setEngine(_ kind: VoiceEngineKind) {
        guard kind != engine, engines.available.contains(kind) else { return }
        stop()
        let old = synthesizer
        enqueue {
            await old?.unload()
        }
        synthesizerRevision += 1
        isLoaded = false
        engine = kind
        chosenEngine = kind
        synthesizer = engines.make(kind)
        problem = nil
        save(settings)
        onEngineChange(kind)
        prepare()
    }

    /// The device a translation would go to now, for Settings.
    func currentDevice() -> AudioOutput? {
        SpeechOutputChoice.resolve(output, outputs: outputs())
    }

    /// Writes down what is said in `sample` with the speech model, then keeps both in
    /// memory as the voice to imitate, in place of any before it. The voice model reads the
    /// words along with the audio. Neither is logged or saved. A sample without speech, or
    /// one the speech model could not take, is not used and the voice before it stays.
    func useVoice(_ sample: VoiceSample) async {
        voiceRequest += 1
        let request = voiceRequest
        isListeningToVoice = true
        problem = nil
        let started = ContinuousClock.now
        let transcript: String
        do {
            transcript = try await transcribeVoice(sample).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard request == voiceRequest else { return }
            isListeningToVoice = false
            problem = String(localized: "Orra could not listen to the voice sample. Choose it again once the speech model is ready.")
            logger.error("The voice sample could not be transcribed: \(String(reflecting: type(of: error)), privacy: .public)")
            return
        }
        guard request == voiceRequest else { return }
        isListeningToVoice = false
        guard transcript.contains(where: { $0.isLetter || $0.isNumber }) else {
            problem = String(localized: "Orra heard no speech in the voice sample.")
            logger.notice("No speech in a voice sample of \(sample.seconds, format: .fixed(precision: 1), privacy: .public) s")
            return
        }
        var heard = sample
        heard.transcript = transcript
        voice = heard
        voiceSeconds = sample.seconds
        let synthesizer = synthesizer
        Task { await synthesizer?.forgetVoice() }
        // Times only, never the words.
        logger.notice("A voice sample of \(sample.seconds, format: .fixed(precision: 1), privacy: .public) s is in memory, written down in \(started.duration(to: .now), privacy: .public)")
    }

    /// Drops the voice sample, what is said in it, and anything the model derived from
    /// it. The model's own voice speaks after this.
    func forgetVoice() {
        voiceRequest += 1
        isListeningToVoice = false
        voice = nil
        voiceSeconds = nil
        let synthesizer = synthesizer
        Task { await synthesizer?.forgetVoice() }
    }

    func reportVoiceProblem(_ message: String) {
        problem = message
    }

    /// Loads the model ahead of the first translation, when Speak Translation is on and
    /// the model is in place. Waits for a dictation under way.
    func prepare() {
        guard speaks else { return }
        let generation = generation
        enqueue { [weak self] in
            guard let self, generation == self.generation, self.folders() != nil else { return }
            await self.waitWhileDictating(generation)
            _ = await self.loadIfNeeded()
        }
    }

    /// Queues `text` to be spoken in `language` after the translations before it.
    func speak(_ text: String, in language: TranslationTarget) {
        guard speaks else { return }
        let generation = generation
        enqueue { [weak self] in
            await self?.run(text, in: language, generation: generation)
        }
    }

    /// Stops what is playing and drops what is queued.
    func stop() {
        generation += 1
        playback.stop()
        if state == .speaking {
            state = .idle
        }
    }

    /// Waits for the queue. Internal for tests.
    func waitUntilDone() async {
        while let current = queue {
            await current.value
            if queue == current {
                return
            }
        }
    }

    private func unload() {
        let synthesizer = synthesizer
        enqueue { [weak self] in
            await synthesizer?.unload()
            self?.isLoaded = false
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }

    private func run(_ text: String, in language: TranslationTarget, generation: Int) async {
        guard generation == self.generation, let synthesizer else { return }
        guard let device = SpeechOutputChoice.resolve(output, outputs: outputs()) else {
            problem = output.map { String(localized: "\($0.name) is not connected, so the translation was not spoken.") }
                ?? String(localized: "Choose where Orra speaks the translation in Settings.")
            logger.notice("No output device for the spoken translation")
            return
        }
        await waitWhileDictating(generation)
        guard generation == self.generation, await loadIfNeeded() else { return }
        do {
            try playback.start(on: device)
        } catch {
            problem = String(localized: "Orra could not play into \(device.name).")
            logger.error("The output device refused playback: \(String(describing: error), privacy: .public)")
            return
        }
        state = .speaking
        problem = nil
        let started = ContinuousClock.now
        var firstSound: Duration?
        let pieces = SpeechChunks.split(text)
        speaking: for piece in pieces {
            await waitWhileDictating(generation)
            guard generation == self.generation else { break }
            do {
                for try await audio in synthesizer.speak(piece, in: language, voice: voice) {
                    guard generation == self.generation else { break speaking }
                    if firstSound == nil {
                        firstSound = started.duration(to: .now)
                    }
                    playback.play(audio)
                }
            } catch {
                problem = String(localized: "The voice model could not speak this translation.")
                logger.error("Speaking failed with \(String(reflecting: type(of: error)), privacy: .public)")
                break
            }
        }
        if generation == self.generation {
            await playback.finish()
            playback.stop()
            state = .idle
        }
        // Times and counts only, never text.
        logger.notice("Spoke \(pieces.count, privacy: .public) pieces in \(language.logName, privacy: .public), first sound after \(firstSound.map { "\($0)" } ?? "none", privacy: .public), done after \(started.duration(to: .now), privacy: .public), voice sample: \(self.voice != nil, privacy: .public)")
    }

    private func loadIfNeeded() async -> Bool {
        guard !isLoaded else { return true }
        guard let synthesizer else { return false }
        guard let folders = folders() else {
            problem = String(localized: "The voice model is not on this Mac yet.")
            return false
        }
        state = .loading
        defer {
            if state == .loading {
                state = .idle
            }
        }
        let started = ContinuousClock.now
        let revision = synthesizerRevision
        do {
            try await synthesizer.load(model: folders.model, codec: folders.codec)
            // The user picked another model while this one loaded. Its unload is queued.
            guard revision == synthesizerRevision else { return false }
            isLoaded = true
            logger.notice("The voice model \(self.engine?.name ?? "none", privacy: .public) loaded in \(started.duration(to: .now), privacy: .public)")
            return true
        } catch {
            problem = String(localized: "The voice model could not be loaded.")
            logger.error("The voice model failed to load: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Dictation first: waits while the user dictates, so the voice model does not take
    /// the GPU from the speech and cleanup models.
    private func waitWhileDictating(_ generation: Int) async {
        while isDictating(), generation == self.generation {
            try? await Task.sleep(for: dictationPoll)
        }
    }
}
