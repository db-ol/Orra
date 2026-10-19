import Foundation
import Observation
import os

/// What PushToTalkController needs to speak a translation. Closures, so tests pass fakes.
struct TranslationVoice {
    /// Whether a translation is spoken: Speak Translation is on and this build can speak.
    var speaks: () -> Bool
    /// Whether a spoken translation into this language is pasted too.
    var alsoPastes: (TranslationTarget) -> Bool
    /// Queues a translation to be spoken, and returns at once.
    var speak: (String, TranslationTarget) -> Void

    static let off = TranslationVoice(speaks: { false }, alsoPastes: { _ in true }, speak: { _, _ in })
}

/// Speak Translation: speaks what the translation key translated, in a voice model, into
/// an output device such as Orra's own microphone device, so the other side of a call
/// hears it. Optionally in the voice of a sample the user recorded, which stays in memory
/// only, unless the user turns on Remember my voice, which saves its audio on this Mac
/// (VoiceSampleFile). Translations are spoken one after another in the order they came.
/// Dictation comes first: a piece waits to be synthesized while the user dictates, so the
/// speech and cleanup models are not kept waiting for the GPU by the voice. No text and no
/// audio is logged, and no text is saved.
@Observable
final class TranslationSpeech {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case loading
        case speaking
    }

    private(set) var isOn: Bool
    private(set) var alsoPastes: Bool
    /// Whether the speech model checks the words of each whole sentence before it plays,
    /// see SpeechWordCheck.
    private(set) var checksWords: Bool
    /// The output the user chose, nil for Orra's own microphone device when it is there.
    private(set) var output: SpeechOutputChoice?
    private(set) var state = State.idle
    /// Why the last translation was not spoken, for Settings and the menu. Cleared when a
    /// translation is spoken or a setting changes.
    private(set) var problem: String?
    /// The length of the voice sample in memory, nil without one.
    private(set) var voiceSeconds: Double?
    /// Remember my voice: the voice sample's audio is saved on this Mac until the user
    /// removes it, and loaded when Orra starts. Off until the user turns it on.
    private(set) var remembersVoice: Bool
    /// Whether a voice sample's audio is on this Mac: the sample in memory once its file is
    /// written, or one saved earlier that is not loaded yet. Settings offers Remove while it
    /// is true, also without a sample in memory.
    private(set) var voiceIsSaved = false
    /// Why the voice sample could not be saved on this Mac or loaded from it. Apart from
    /// `problem`, so Settings shows it whether Speak translations is on or off. Cleared when
    /// a sample is picked or removed, or Remember my voice changes.
    private(set) var voiceFileProblem: String?
    /// The speech model is writing down what is said in a voice sample the user recorded.
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
    /// Writes down what the voice model said in a sentence, in the language it was asked to
    /// speak, with the speech model of dictation, for the word check. AppDelegate sets it,
    /// tests pass fakes. A sentence it throws for plays unchecked. The language is nil for
    /// no hint, see SpeechWordCheck.hint(for:in:).
    @ObservationIgnored var transcribeSpeech: (SpokenAudio, TranslationTarget?) async throws -> String = { _, _ in throw TranscriptionError.modelMissing }
    /// Returns once the speech model is loaded, so a voice sample saved on this Mac can be
    /// written down at launch. AppDelegate sets it, tests pass fakes.
    @ObservationIgnored var waitForSpeechModel: () async -> Void = {}
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
    /// Counts the samples used and removed and the times Remember my voice was turned off,
    /// so a saved sample still waiting to load does not take the place of what the user
    /// chose. A sample the speech model could not take does not count.
    @ObservationIgnored private var voiceChoice = 0
    /// Where Remember my voice keeps the voice sample, nil to keep it in memory only.
    @ObservationIgnored private let voiceFile: VoiceSampleFile?
    /// The writes and deletions of the voice sample's file, one after another.
    @ObservationIgnored private var fileWork: Task<Void, Never>?
    /// Counts the writes and deletions asked for, so only the last one says whether the
    /// sample is saved.
    @ObservationIgnored private var fileRevision = 0
    /// Whether the last change asked for of the file is its deletion, see
    /// removeVoiceFileBeforeQuit().
    @ObservationIgnored private var removesVoiceFile = false
    /// The load of the voice sample saved on this Mac, see restoreVoice().
    @ObservationIgnored private var restoring: Task<Void, Never>?
    /// The translations queued and being spoken, one after another.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// The translation or the load that the queue runs now, in a task of its own that
    /// stop() cancels. So a piece or a load that waits for the model gate leaves the gate's
    /// queue. It never takes the gate alone later and holds captions and dictation back for
    /// work nobody waits for. A piece the voice model already makes goes on to its end, see
    /// ExclusiveSynthesizer.
    @ObservationIgnored private var stoppable: Task<Void, Never>?
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
        var checksWords = SpeechPreference.checksWordsByDefault
        /// Remember my voice. Whether the voice sample is on disk, never the sample itself.
        var remembersVoice = false

        static func load(from defaults: UserDefaults = .standard) -> Settings {
            Settings(
                isOn: SpeechPreference.isOn(in: defaults),
                alsoPastes: SpeechPreference.alsoPastes(in: defaults),
                output: SpeechPreference.output(in: defaults),
                voiceModel: SpeechPreference.voiceModel(in: defaults),
                checksWords: SpeechPreference.checksWords(in: defaults),
                remembersVoice: SpeechPreference.remembersVoice(in: defaults)
            )
        }

        func save(to defaults: UserDefaults = .standard) {
            SpeechPreference.saveIsOn(isOn, to: defaults)
            SpeechPreference.saveAlsoPastes(alsoPastes, to: defaults)
            SpeechPreference.saveOutput(output, to: defaults)
            SpeechPreference.saveVoiceModel(voiceModel, to: defaults)
            SpeechPreference.saveChecksWords(checksWords, to: defaults)
            SpeechPreference.saveRemembersVoice(remembersVoice, to: defaults)
        }
    }

    /// - Parameters:
    ///   - engines: The voice models of this build. Tests pass fakes.
    ///   - playback: Plays into the output. Tests pass fakes.
    ///   - outputs: The output devices connected now. Tests pass fakes.
    ///   - folders: The voice model's folders once both are installed, nil before.
    ///   - settings: As saved.
    ///   - save: Saves the settings after they change.
    ///   - voiceFile: Where Remember my voice keeps the voice sample, nil to keep it in
    ///     memory only. Tests pass a temporary folder.
    ///   - dictationPoll: How often a waiting piece checks whether the dictation ended.
    init(
        engines: VoiceEngines,
        playback: any SpeechPlayback,
        outputs: @escaping () -> [AudioOutput],
        folders: @escaping () -> VoiceModelFolders?,
        settings: Settings = Settings(),
        save: @escaping (Settings) -> Void = { _ in },
        voiceFile: VoiceSampleFile? = nil,
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
        self.checksWords = settings.checksWords
        self.output = settings.output
        self.remembersVoice = settings.remembersVoice
        self.save = save
        self.voiceFile = voiceFile
        self.dictationPoll = dictationPoll
    }

    /// For PushToTalkController. A translation is pasted even with Also Paste off while
    /// the voice model is not on this Mac, no device would take the voice or the model
    /// does not speak its language, as CosyVoice3 does not speak Japanese, so it is not lost
    /// to a translation that cannot be spoken.
    var voiceForDictation: TranslationVoice {
        TranslationVoice(
            speaks: { [weak self] in self?.speaks == true },
            alsoPastes: { [weak self] language in
                guard let self else { return true }
                return self.alsoPastes || self.folders() == nil || self.currentDevice() == nil || self.engine?.speaks(language) == false
            },
            speak: { [weak self] text, language in self?.speak(text, in: language) }
        )
    }

    private var settings: Settings {
        Settings(isOn: isOn, alsoPastes: alsoPastes, output: output, voiceModel: chosenEngine, checksWords: checksWords, remembersVoice: remembersVoice)
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        problem = nil
        save(settings)
        if on {
            prepare()
            if remembersVoice {
                restoreVoice()
            }
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

    func setChecksWords(_ on: Bool) {
        guard on != checksWords else { return }
        checksWords = on
        save(settings)
    }

    func setOutput(_ choice: SpeechOutputChoice?) {
        guard choice != output else { return }
        output = choice
        problem = nil
        save(settings)
    }

    /// Remember my voice. Turning it on saves the voice sample in memory at once, turning
    /// it off deletes the file at once and ends the load of a saved sample still waiting.
    func setRemembersVoice(_ on: Bool) {
        guard on != remembersVoice else { return }
        remembersVoice = on
        voiceFileProblem = nil
        save(settings)
        if !on {
            voiceChoice += 1
            removeVoiceFile()
        } else if let voice {
            saveVoiceFile(voice)
        }
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

    /// What became of a voice sample handed to useVoice.
    nonisolated enum VoiceUse: Equatable, Sendable {
        case used
        /// The speech model heard no words in it.
        case noSpeech
        /// The speech model could not listen to it.
        case failed
        /// Another sample was picked or Remove was clicked meanwhile.
        case dropped
    }

    /// Writes down what is said in `sample` with the speech model, then keeps both in
    /// memory as the voice to imitate, in place of any before it. The voice model reads the
    /// words along with the audio. Neither is logged. With Remember my voice on, the audio
    /// is saved on this Mac in place of the sample before it, never the words. A sample
    /// without speech, or one the speech model could not take, is not used and the voice
    /// before it stays, on disk too.
    @discardableResult
    func useVoice(_ sample: VoiceSample) async -> VoiceUse {
        voiceRequest += 1
        let request = voiceRequest
        isListeningToVoice = true
        problem = nil
        voiceFileProblem = nil
        let started = ContinuousClock.now
        let transcript: String
        do {
            transcript = try await transcribeVoice(sample).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard request == voiceRequest else { return .dropped }
            isListeningToVoice = false
            problem = String(localized: "Orra could not listen to the voice sample. Record it again once the speech model is ready.")
            logger.error("The voice sample could not be transcribed: \(String(reflecting: type(of: error)), privacy: .public)")
            return .failed
        }
        guard request == voiceRequest else { return .dropped }
        isListeningToVoice = false
        guard transcript.contains(where: { $0.isLetter || $0.isNumber }) else {
            problem = String(localized: "Orra heard no speech in the voice sample.")
            logger.notice("No speech in a voice sample of \(sample.seconds, format: .fixed(precision: 1), privacy: .public) s")
            return .noSpeech
        }
        var heard = sample
        heard.transcript = transcript
        voice = heard
        voiceSeconds = sample.seconds
        voiceChoice += 1
        if remembersVoice {
            saveVoiceFile(sample)
        }
        let synthesizer = synthesizer
        Task { await synthesizer?.forgetVoice() }
        // Times only, never the words.
        logger.notice("A voice sample of \(sample.seconds, format: .fixed(precision: 1), privacy: .public) s is in memory, written down in \(started.duration(to: .now), privacy: .public)")
        return .used
    }

    /// Use This Recording, or a file imported, in the recording sheet: uses `sample` and
    /// sets Remember my voice as the sheet's checkbox says, nil to leave it. Off applies
    /// first, so the old file is deleted before anything else. On applies once the sample
    /// is used, so the new sample is written and not the one before it, unless the speech
    /// model heard no speech in the new one. A change in Settings meanwhile wins.
    @discardableResult
    func useVoice(_ sample: VoiceSample, remember: Bool?) async -> VoiceUse {
        if remember == false {
            setRemembersVoice(false)
        }
        let before = remembersVoice
        let use = await useVoice(sample)
        if remember == true, remembersVoice == before {
            setRemembersVoice(true)
        }
        return use
    }

    /// Drops the voice sample, what is said in it, and anything the model derived from
    /// it, on disk too, also a saved sample not loaded yet. The model's own voice speaks
    /// after this.
    func forgetVoice() {
        voiceRequest += 1
        voiceChoice += 1
        isListeningToVoice = false
        voice = nil
        voiceSeconds = nil
        voiceFileProblem = nil
        removeVoiceFile()
        let synthesizer = synthesizer
        Task { await synthesizer?.forgetVoice() }
    }

    /// At launch, and when Speak translations is turned on: with Remember my voice on,
    /// uses the voice sample saved on this Mac as a new recording, so the speech model
    /// writes down what is said in it again. It reads the file only once the speech model
    /// is loaded, so the audio is not held in memory while it waits, and then waits for a
    /// dictation or a sample the user is recording. While Speak translations is off, or in
    /// a build without a voice model, the file is not read, and Settings offers to remove
    /// it. A file that is not a voice sample, is too short or has no speech in it is
    /// deleted, and Settings says so. With the switch off, a file left behind is deleted. A
    /// sample the user picks meanwhile, Remove and the switch turned off win. A sample the
    /// speech model could not take does not.
    func restoreVoice() {
        guard restoring == nil else { return }
        restoring = Task { [weak self] in
            await self?.loadSavedVoice()
            self?.restoring = nil
        }
    }

    /// Waits for restoreVoice(). Internal for tests.
    func waitForVoiceRestore() async {
        while let current = restoring {
            await current.value
        }
    }

    private func loadSavedVoice() async {
        guard let voiceFile else { return }
        guard remembersVoice else {
            removeVoiceFile()
            return
        }
        guard voice == nil else { return }
        let choice = voiceChoice
        // What a write cut short by a crash or a forced quit left behind.
        onVoiceFile {
            await voiceFile.removeLeftovers()
        }
        await waitForVoiceFile()
        guard choice == voiceChoice else { return }
        voiceIsSaved = voiceFile.exists
        guard voiceIsSaved, isOn, canSpeak else { return }
        await waitForSpeechModel()
        guard choice == voiceChoice, isOn else { return }
        let sample: VoiceSample?
        do {
            sample = try await voiceFile.load()
        } catch {
            guard choice == voiceChoice else { return }
            dropSavedVoice()
            // The reason only, never the audio.
            logger.error("The saved voice sample could not be read: \(String(describing: error), privacy: .public)")
            return
        }
        guard choice == voiceChoice else { return }
        guard let sample else {
            voiceIsSaved = false
            return
        }
        while isDictating() || isListeningToVoice, choice == voiceChoice {
            try? await Task.sleep(for: dictationPoll)
        }
        guard choice == voiceChoice, isOn else { return }
        logger.notice("Loading the voice sample of \(sample.seconds, format: .fixed(precision: 1), privacy: .public) s saved on this Mac")
        if await useVoice(sample) == .noSpeech {
            // One message, about the file.
            problem = nil
            dropSavedVoice()
            logger.notice("No speech in the saved voice sample, so it was deleted")
        }
    }

    /// Deletes a saved voice sample Orra could not use, and says so once.
    private func dropSavedVoice() {
        removeVoiceFile()
        voiceFileProblem = String(localized: "Orra could not read the voice sample saved on this Mac and deleted it. Record it again.")
    }

    /// When Orra quits: deletes the voice sample's file at once when the last change asked
    /// for that, since the deletion runs in a task that may not have run yet. So Remove or
    /// the switch turned off right before Quit leaves no audio for the next launch.
    func removeVoiceFileBeforeQuit() {
        guard removesVoiceFile, let voiceFile else { return }
        voiceFile.removeNow()
    }

    /// Waits for the writes and deletions of the voice sample's file. Internal for tests.
    func waitForVoiceFile() async {
        while let current = fileWork {
            await current.value
            if fileWork == current {
                return
            }
        }
    }

    /// Saves the audio of `sample` after the file work before it. When the write fails,
    /// the file before it is deleted too, so no older sample stays on disk.
    private func saveVoiceFile(_ sample: VoiceSample) {
        guard let voiceFile else { return }
        fileRevision += 1
        let revision = fileRevision
        removesVoiceFile = false
        onVoiceFile { [weak self] in
            var saved = true
            do {
                try await voiceFile.save(sample)
            } catch {
                saved = false
                await voiceFile.remove()
                self?.logger.error("The voice sample could not be saved: \(String(reflecting: type(of: error)), privacy: .public)")
            }
            guard let self, revision == self.fileRevision else { return }
            self.voiceIsSaved = saved
            if !saved {
                self.voiceFileProblem = String(localized: "Orra could not save the voice sample on this Mac.")
            }
        }
    }

    private func removeVoiceFile() {
        guard let voiceFile else { return }
        fileRevision += 1
        removesVoiceFile = true
        voiceIsSaved = false
        onVoiceFile {
            await voiceFile.remove()
        }
    }

    private func onVoiceFile(_ work: @escaping () async -> Void) {
        let previous = fileWork
        fileWork = Task {
            await previous?.value
            await work()
        }
    }

    func reportVoiceProblem(_ message: String) {
        problem = message
    }

    /// Loads the model ahead of the first translation, when Speak Translation is on and
    /// the model is in place. Waits for a dictation under way.
    func prepare() {
        guard speaks else { return }
        let generation = generation
        enqueueStoppable { [weak self] in
            guard let self, generation == self.generation, self.folders() != nil else { return }
            await self.waitWhileDictating(generation)
            guard generation == self.generation else { return }
            _ = await self.loadIfNeeded()
        }
    }

    /// Queues `text` to be spoken in `language` after the translations before it.
    func speak(_ text: String, in language: TranslationTarget) {
        guard speaks else { return }
        let generation = generation
        enqueueStoppable { [weak self] in
            await self?.run(text, in: language, generation: generation)
        }
    }

    /// Stops what is playing and drops what is queued. A piece or a load that waits for
    /// the model gate leaves it. A piece the voice model already makes goes on to its end
    /// unheard, since its MLX work must stay inside the gate.
    func stop() {
        generation += 1
        stoppable?.cancel()
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

    /// Queues `work` like enqueue, in a task that stop() cancels, see `stoppable`. Only for
    /// work that a stop drops anyway, which checks the generation. Each gets a task of its
    /// own, so a stop never reaches the work queued after it, such as the next translation.
    private func enqueueStoppable(_ work: @escaping () async -> Void) {
        enqueue { [weak self] in
            let task = Task { await work() }
            self?.stoppable = task
            await task.value
        }
    }

    private func run(_ text: String, in language: TranslationTarget, generation: Int) async {
        guard generation == self.generation, let synthesizer else { return }
        // A model that does not speak the language would play other words.
        if let engine, !engine.speaks(language) {
            problem = String(localized: "CosyVoice3 does not speak Japanese, so the translation was not spoken. Qwen3-TTS does.")
            logger.notice("The voice model does not speak \(language.logName, privacy: .public), so the translation was not spoken")
            return
        }
        guard let device = SpeechOutputChoice.resolve(output, outputs: outputs()) else {
            problem = output.map { String(localized: "\($0.name) is not connected, so the translation was not spoken.") }
                ?? String(localized: "Choose where Orra speaks the translation in Settings.")
            logger.notice("No output device for the spoken translation")
            return
        }
        await waitWhileDictating(generation)
        // Again after the load, which a stop does not always cut short.
        guard generation == self.generation, await loadIfNeeded(), generation == self.generation else { return }
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
        var tally = PieceTally()
        let pieces = SpeechChunks.split(text)
        speaking: for piece in pieces {
            await waitWhileDictating(generation)
            guard generation == self.generation else { break }
            do {
                let outcome = try await say(piece, in: language, with: synthesizer, generation: generation, tally: &tally) {
                    if firstSound == nil {
                        firstSound = started.duration(to: .now)
                    }
                }
                tally.count(outcome)
                if outcome == .stopped {
                    break speaking
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
            if tally.skipped > 0, problem == nil {
                problem = String(localized: "The voice model failed twice on a sentence, so Orra skipped it.")
            }
        }
        // Times and counts only, never text.
        logger.notice("Spoke \(pieces.count, privacy: .public) pieces in \(language.logName, privacy: .public), first sound after \(firstSound.map { "\($0)" } ?? "none", privacy: .public), done after \(started.duration(to: .now), privacy: .public), voice sample: \(self.voice != nil, privacy: .public)")
        if tally.hasNews {
            // Counts and reasons only, never text or audio.
            logger.notice("Speech check: \(tally.retried, privacy: .public) pieces made again, \(tally.skipped, privacy: .public) skipped, \(tally.closest, privacy: .public) played closer try, \(tally.cut, privacy: .public) streamed pieces cut, reasons \(tally.reasons, privacy: .public)")
        }
        if tally.wordChecks > 0 || tally.unchecked > 0 {
            // Counts and times only, never what was heard.
            logger.notice("Word check: \(tally.wordChecks, privacy: .public) pieces in \(tally.wordCheckTime, privacy: .public), \(tally.unchecked, privacy: .public) unchecked")
        }
    }

    /// What became of a piece.
    nonisolated enum PieceOutcome: Equatable, Sendable {
        /// Played, on the second try when the first failed the check for `firstTry`.
        case spoken(firstTry: SpeechCheck.Verdict?)
        /// Failed the check twice and not played.
        case skipped(SpeechCheck.Verdict, SpeechCheck.Verdict)
        /// Failed only the word check twice, and the try with fewer wrong units played, see
        /// `SpeechWordCheck.mostWrongShareToPlay`.
        case closest
        /// Streamed and cut at the longest it may run.
        case cut
        /// Stopped by the user.
        case stopped
    }

    /// The counts of one translation for the log.
    private struct PieceTally {
        var retried = 0
        var skipped = 0
        /// Pieces that failed only the word check twice and played the closer try.
        var closest = 0
        var cut = 0
        /// Pieces the speech model listened to for the word check, and the time it took.
        var wordChecks = 0
        var wordCheckTime = Duration.zero
        /// Pieces the word check could not run on, such as while the speech model is not
        /// loaded.
        var unchecked = 0
        var verdicts: [SpeechCheck.Verdict] = []

        mutating func count(_ outcome: PieceOutcome) {
            switch outcome {
            case .spoken(let firstTry):
                if let firstTry {
                    retried += 1
                    verdicts.append(firstTry)
                }
            case .skipped(let first, let second):
                retried += 1
                skipped += 1
                verdicts += [first, second]
            case .closest:
                retried += 1
                closest += 1
                verdicts += [.wrongWords, .wrongWords]
            case .cut:
                cut += 1
                verdicts.append(.tooLong)
            case .stopped:
                break
            }
        }

        var hasNews: Bool {
            retried > 0 || cut > 0
        }

        var reasons: String {
            verdicts.isEmpty ? "none" : verdicts.map(\.rawValue).joined(separator: " ")
        }
    }

    /// Speaks one piece. A piece that comes whole is checked before it plays (SpeechCheck,
    /// then SpeechWordCheck when that is on): one that fails is made once more, and skipped
    /// when it fails again, so a cut off sentence, near silence, a loop or other words never
    /// reach the other side. A piece whose two tries both failed only the word check plays
    /// the try with fewer wrong units, unless even that one is mostly wrong
    /// (`SpeechWordCheck.mostWrongShareToPlay`), since a sentence that is a little off says
    /// more than silence. Both voice models draw their samples from MLX's random state,
    /// which moves on with every draw, so the second try is a new draw. A streamed piece plays as it comes, so only its length can
    /// be held to the check: it is cut at the longest its text may run. `heard` is called
    /// when a part of the piece is queued to play.
    private func say(_ piece: String, in language: TranslationTarget, with synthesizer: any SpeechSynthesizer, generation: Int, tally: inout PieceTally, heard: () -> Void) async throws -> PieceOutcome {
        let voice = voice
        if synthesizer.streams(voice: voice) {
            let longest = SpeechCheck.longestSeconds(for: piece)
            var seconds = 0.0
            for try await audio in synthesizer.speak(piece, in: language, voice: voice) {
                guard generation == self.generation else { return .stopped }
                let rate = Double(max(audio.sampleRate, 1))
                let length = Double(audio.samples.count) / rate
                if seconds + length > longest {
                    let room = Int((longest - seconds) * rate)
                    if room > 0 {
                        heard()
                        playback.play(SpokenAudio(samples: Array(audio.samples.prefix(room)), sampleRate: audio.sampleRate))
                    }
                    // Ending the stream here drops the rest of the piece, as a stop does.
                    return .cut
                }
                seconds += length
                heard()
                playback.play(audio)
            }
            // A stop ends the stream early, without an error.
            guard generation == self.generation else { return .stopped }
            return .spoken(firstTry: nil)
        }
        var verdicts: [SpeechCheck.Verdict] = []
        // The try that failed only the word check with the fewest wrong units.
        var closest: (parts: [SpokenAudio], errors: SpeechWordCheck.Errors)?
        for _ in 0..<2 {
            if !verdicts.isEmpty {
                // The second try is a new piece for the GPU, so dictation goes first again.
                await waitWhileDictating(generation)
                guard generation == self.generation else { return .stopped }
            }
            var parts: [SpokenAudio] = []
            for try await audio in synthesizer.speak(piece, in: language, voice: voice) {
                guard generation == self.generation else { return .stopped }
                parts.append(audio)
            }
            guard generation == self.generation else { return .stopped }
            let whole = SpokenAudio(samples: parts.flatMap(\.samples), sampleRate: parts.first?.sampleRate ?? 24_000)
            var verdict = SpeechCheck.verdict(for: whole, text: piece)
            if verdict == .good, checksWords, !SpeechWordCheck.units(of: piece).isEmpty {
                guard let words = await checkWords(of: whole, against: piece, in: language, generation: generation, tally: &tally) else { return .stopped }
                verdict = words.verdict
                if verdict == .wrongWords, let errors = words.errors, errors.wrong < (closest?.errors.wrong ?? .max) {
                    closest = (parts, errors)
                }
            }
            if verdict == .good {
                for part in parts {
                    heard()
                    playback.play(part)
                }
                return .spoken(firstTry: verdicts.first)
            }
            verdicts.append(verdict)
        }
        if verdicts == [.wrongWords, .wrongWords], let closest, closest.errors.share <= SpeechWordCheck.mostWrongShareToPlay {
            for part in closest.parts {
                heard()
                playback.play(part)
            }
            return .closest
        }
        return .skipped(verdicts[0], verdicts[1])
    }

    /// The word check of a whole piece: the speech model writes down what `audio` says, in
    /// `language` unless SpeechWordCheck.hint(for:in:) leaves the hint out, and SpeechWordCheck compares it with `piece`. The speech model is
    /// dictation's, so this waits while the user dictates, as a second try does. A piece the
    /// speech model could not listen to passes. Nil when the user stopped. The errors are nil
    /// when the speech model could not listen.
    private func checkWords(of audio: SpokenAudio, against piece: String, in language: TranslationTarget, generation: Int, tally: inout PieceTally) async -> (verdict: SpeechCheck.Verdict, errors: SpeechWordCheck.Errors?)? {
        await waitWhileDictating(generation)
        guard generation == self.generation else { return nil }
        let started = ContinuousClock.now
        let heard: String
        do {
            heard = try await transcribeSpeech(audio, SpeechWordCheck.hint(for: piece, in: language))
        } catch {
            tally.unchecked += 1
            return generation == self.generation ? (.good, nil) : nil
        }
        tally.wordChecks += 1
        tally.wordCheckTime += started.duration(to: .now)
        guard generation == self.generation else { return nil }
        let errors = SpeechWordCheck.errors(text: piece, heard: heard)
        return (errors.passes ? .good : .wrongWords, errors)
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
            // A load of the model the user switched away from says nothing about the new one,
            // and a load that a stop took out of the model gate's queue says nothing at all.
            guard revision == synthesizerRevision, !(error is CancellationError) else { return false }
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
