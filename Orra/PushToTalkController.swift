import AppKit
import ApplicationServices
import Observation
import os

extension Logger {
    /// Dictation, from the talk key to the paste. States, timings and counts only, never
    /// text or audio.
    nonisolated static let pushToTalk = Logger(subsystem: ProblemReport.subsystem, category: "push-to-talk")
}

/// What the recording indicator and the sounds follow. A dictation sends listening,
/// transcribing, recordingStopped and finished, in that order. Listening waits until the
/// hold has lasted a moment and the microphone has delivered sound, so a shortcut with
/// the talk key, such as right Control+C, sends nothing, and speech after the start sound
/// is recorded. A press that has not counted yet sends nothing either. A hands free
/// dictation sends handsFree in place of listening, or after it when a hold turned into
/// one. A hold that ends early
/// skips to finished, which comes only when there is a message to show or an indicator to
/// clear.
nonisolated enum DictationCue: Equatable, Sendable {
    /// The hold has lasted long enough to be a dictation, and the microphone delivers sound.
    /// `translation` is the direction when the translation key started it, so the
    /// indicator shows that the text will be pasted translated.
    case listening(translation: TranslationDirection?)
    /// A hands free dictation records. The hint says how to finish it, such as "Press
    /// right Control to finish". `translation` as for listening.
    case handsFree(finishHint: String, translation: TranslationDirection? = nil)

    /// A dictation of the talk key is recording.
    static let listening = DictationCue.listening(translation: nil)
    /// The talk key was released after a hold long enough to transcribe.
    case transcribing
    /// The microphone stopped after a hold long enough to transcribe. A recording without
    /// sound or without speech then ends with a message.
    case recordingStopped
    /// The hold is over. The message says why nothing was pasted, when there is a reason.
    case finished(message: String?)
}

/// Connects the talk key, the microphone, the speech model and text insertion, and
/// publishes the state for the menu bar.
///
/// A hold records. The release stops the recording, the speech model turns it into text
/// off the main actor, and the text is pasted into the frontmost app. A quick double press
/// records hands free until the next press of the key, see PushToTalkStateMachine.
///
/// While translation is on, the translation key works the same way, and its dictation is
/// translated after the rule steps, see TranslationStep. Whenever the translation cannot
/// be used, the text is pasted without it, never nothing.
@Observable
final class PushToTalkController {
    nonisolated enum ModelState: Equatable, Sendable {
        case notLoaded
        case loading
        case ready
        /// Why the model is not there to use. The menu and the welcome window show it.
        case unavailable(ModelProblem)
    }

    /// Why the speech model could not be loaded.
    nonisolated enum ModelProblem: Equatable, Sendable {
        case missing
        case failedToLoad

        /// The reason as the menu shows it, in the language of `locale`.
        func message(in locale: Locale = .interface) -> String {
            switch self {
            case .missing: String(localized: LocalizedStringResource("The speech model is not on this Mac", locale: locale))
            case .failedToLoad: String(localized: LocalizedStringResource("The speech model could not be loaded", locale: locale))
            }
        }
    }

    /// The current push to talk state.
    private(set) var state: PushToTalkStateMachine.State = .idle
    /// The key or combination that starts a dictation. Saved through `saveTalkKey`
    /// whenever it changes.
    private(set) var talkKey: Hotkey
    /// How the talk key starts a dictation. Saved through `saveTriggerMode` whenever it
    /// changes.
    private(set) var talkMode: TriggerMode
    /// A second key that starts a dictation just as the talk key does, in the talk key's
    /// mode, or nil. Never the talk key or the translation key, see SecondTalkKey. Saved
    /// through `saveSecondTalkKey` whenever it changes.
    private(set) var secondTalkKey: TalkKey?
    /// Whether the user has chosen the talk key, here or in an earlier launch. The welcome
    /// window marks its talk key step as done then.
    private(set) var hasChosenTalkKey: Bool
    /// The key that starts a dictation that is pasted translated, while translation is
    /// on, see `translationKeyIsOn`. Never the talk key. Saved through
    /// `saveTranslationKey` when the user picks it, or when picking the talk key moved it.
    private(set) var translationKey: Hotkey
    /// How the translation key starts a dictation, saved as for the talk key.
    private(set) var translationMode: TriggerMode
    /// Whether the translation key is watched: translation is on. AppDelegate keeps it in
    /// step with the Translation switch in Settings.
    private(set) var translationKeyIsOn = false
    /// Whether a quick double press of the talk key, or of the translation key, starts a
    /// hands free dictation. Saved through `saveHandsFree` whenever it changes.
    private(set) var handsFreeOn: Bool
    /// Which key the user records by pressing it, if any.
    private(set) var choosingKeySlot: KeySlot?
    /// True while the user records a talk key by pressing it.
    var isChoosingTalkKey: Bool {
        choosingKeySlot == .talk
    }
    /// Why the last press while recording a key cannot be one, such as Shift.
    private(set) var keyChoiceRejection: KeyRecorder.Rejection?
    /// Set when the latest key the user picked was the other key's, so the two keys
    /// swapped. Cleared when the user records a key again.
    private(set) var keySwap: KeySwap?
    /// The microphone the user chose in Orra, or nil for the system default input. Saved
    /// through `saveMicrophone` whenever it changes.
    private(set) var microphone: MicrophoneChoice?
    /// The user's words and names with their dates. The speech model gets the most recent
    /// of them with every dictation, see `Vocabulary.forModel(_:)`. Saved through
    /// `saveVocabulary` whenever they change, also when a paste uses one. Never logged.
    private(set) var vocabulary: [VocabularyWord]
    /// Whether fillers such as 呃 and um are removed before the paste, see FillerRules.
    /// Saved through `saveRemovesFillerWords` whenever it changes.
    private(set) var removesFillerWords: Bool
    /// Whether numbers spoken in Chinese, such as 百分之五十, are written as digits before
    /// the paste, see NumberRules. Saved through `saveWritesNumbersAsDigits` whenever it
    /// changes.
    private(set) var writesNumbersAsDigits: Bool
    /// True while the keyboard tap is installed, which needs Accessibility access.
    private(set) var isHotkeyActive = false
    /// True while Settings records a voice sample with the microphone. A press of the talk
    /// key or the translation key records nothing meanwhile.
    private(set) var isRecordingVoiceSample = false
    /// Microphone permission as last seen. Refreshed at start, on every hold, and after
    /// a request.
    private(set) var microphoneAccess: MicrophoneAccess = .notDetermined
    /// Whether the speech model can take dictation yet.
    private(set) var modelState: ModelState = .notLoaded
    /// The latest error, shown in the menu until the next hold.
    private(set) var problem: String?
    /// The latest note that is not an error, shown in the menu until the next hold.
    private(set) var notice: String?
    /// What to do about the microphone after the latest hold, or which microphone recorded
    /// because the chosen one was not connected. Kept apart from `notice`, so a paste
    /// notice cannot hide it. Shown in the menu until the next hold.
    private(set) var microphoneNotice: String?
    /// True when Sound settings can help with the latest problem: the system default input
    /// delivered no sound, or the chosen microphone could not start and has to be picked
    /// there. The menu then offers the Sound settings.
    private(set) var suggestsSoundSettings = false
    /// The text of the latest dictation, kept in memory only, so the menu can copy it when
    /// the paste missed. Never logged.
    private(set) var lastTranscript: String?
    /// The latest dictation before the model changed it, so Paste Original Text in the
    /// menu can bring it back: the text before translation when the paste was translated,
    /// and otherwise the text as the rule steps left it, when the cleanup model changed it.
    /// In memory only, never logged.
    private(set) var originalText: String?
    /// Receives the cues for the recording indicator and the sounds. AppDelegate sets it.
    @ObservationIgnored var onCue: (DictationCue) -> Void = { _ in }
    /// Told after each paste, with the text, the app it went into, the text before the
    /// cleanup model changed it, if it did, and the words Orra replaced, placed in the text
    /// before the cleanup, so Orra can learn from a correction. Never told about a
    /// translated paste, since a fix of a translation is no misheard word. AppDelegate sets
    /// it.
    @ObservationIgnored var onPasted: (_ text: String, _ app: pid_t, _ beforeCleanup: String?, _ replacements: [Replacement]) -> Void = { _, _, _, _ in }
    /// The kept word pairs whose words replace what the speech model wrote, see
    /// WordReplacement. Read once per dictation. AppDelegate sets it.
    @ObservationIgnored var replacementPairs: () -> [Correction] = { [] }
    /// Told when Paste Original Text pastes over a cleaned paste, with the cleaned text, so
    /// learning stops following it.
    @ObservationIgnored var onPasteOriginal: (_ cleaned: String) -> Void = { _ in }
    /// Told the time of every step after a dictation was pasted. Durations only, never
    /// text. LatencyMeasurementTests reads it, the app leaves it alone.
    @ObservationIgnored var onTimings: (DictationTimings) -> Void = { _ in }

    @ObservationIgnored private let capture: AudioCapture
    @ObservationIgnored private let transcription: Transcription
    @ObservationIgnored private let cleanup: CleanupModel
    @ObservationIgnored private let translation: TranslationModel
    @ObservationIgnored private let voice: TranslationVoice
    /// The direction of the dictation under way when the translation key started it, read
    /// at its start. Nil for a dictation of the talk key.
    @ObservationIgnored private var holdTranslation: TranslationDirection?
    @ObservationIgnored private let insert: @MainActor (String) async -> InsertionResult
    @ObservationIgnored private let frontmostApp: @MainActor () -> pid_t?
    @ObservationIgnored private let lidIsClosed: @MainActor () -> Bool
    @ObservationIgnored private let isTrusted: @MainActor () -> Bool
    @ObservationIgnored private let installTap: HotkeyTap.Install
    @ObservationIgnored private let maximumRecordingDuration: Duration
    @ObservationIgnored private let minimumHold: Duration
    @ObservationIgnored private let releaseTail: Duration
    @ObservationIgnored private let accessCheckDelay: Duration
    @ObservationIgnored private let listeningCueDelay: Duration
    @ObservationIgnored private let soundWaitLimit: Duration
    /// Sends the listening cue once the hold has lasted `listeningCueDelay` and the
    /// microphone delivered sound.
    @ObservationIgnored private var listeningCueTask: Task<Void, Never>?
    /// Whether the current hold has shown the indicator, so its end has to clear it.
    @ObservationIgnored private var indicatorShown = false
    @ObservationIgnored private var recordingLimitTask: Task<Void, Never>?
    /// Starts the microphone off the main thread. Its value is when the start returned, or
    /// nil when the microphone did not start.
    @ObservationIgnored private var captureStart: Task<ContinuousClock.Instant?, Never>?
    /// Stops the microphone after a cancelled hold. The next start waits for it, so a
    /// late cancel cannot stop the recording of a newer hold, and so does the next cancel.
    @ObservationIgnored private var captureCancel: Task<Void, Never>?
    /// How the microphone started for the current hold, for the timing log. Its `counted`
    /// time also tells whether the hold counted, see `holdCounted`, and `minimumHold` counts
    /// from it. A press that captured early records from its key down but counts only after
    /// its wait, as before, so holding a key that waits alone a little longer than the wait
    /// is still too short to transcribe.
    @ObservationIgnored private var holdTimings: CaptureTimings?
    /// Whether the current hold counted as a dictation. A press that waits counts once its
    /// wait ends, and until then it shows and says nothing.
    private var holdCounted: Bool {
        holdTimings?.counted != nil
    }
    /// Counts the holds that started the microphone, so a late failure of an older start
    /// leaves the current hold alone.
    @ObservationIgnored private var holdNumber = 0
    /// The microphone chosen when the current hold started.
    @ObservationIgnored private var holdMicrophone: MicrophoneChoice?
    /// Why the current hold ended without a paste, for the indicator, when neither
    /// `problem` nor `notice` says it. The menu shows these states in its own lines.
    @ObservationIgnored private var holdMessage: String?
    /// Held from the start of a recording until its text is pasted or the hold ends.
    /// Orra is a menu bar app without windows, which App Nap may throttle, and someone is
    /// waiting for this work.
    @ObservationIgnored private var userActivity: (any NSObjectProtocol)?
    /// Held from the press of a key until the dictation is pasted or the hold ends, so a
    /// voice request that waits cannot come in between the dictation's model calls, see
    /// ModelGate.reserve. Nil with a speech model that runs at no gate, as a test's fake.
    /// Nothing in between waits for a voice request: a translation to speak is only queued.
    @ObservationIgnored private var gateReservation: ModelGate.Reservation?
    @ObservationIgnored private var machine = PushToTalkStateMachine()
    @ObservationIgnored private var tap: HotkeyTap?
    @ObservationIgnored private let saveTalkKey: (Hotkey) -> Void
    @ObservationIgnored private let saveTranslationKey: (Hotkey) -> Void
    @ObservationIgnored private let saveSecondTalkKey: (TalkKey?) -> Void
    @ObservationIgnored private let saveTriggerMode: (TriggerMode, KeySlot) -> Void
    @ObservationIgnored private let saveHandsFree: (Bool) -> Void
    /// Watches Orra's own key presses while the user chooses a talk key and the tap is not
    /// installed, which needs no permission.
    /// The local event monitors while the user records a talk key.
    @ObservationIgnored private var keyChoiceMonitors: [Any] = []
    /// Ends the recording of a talk key when Orra stops being the active app.
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    /// Follows the presses while the user records a talk key.
    @ObservationIgnored private var keyRecorder = KeyRecorder()
    @ObservationIgnored private let saveMicrophone: (MicrophoneChoice?) -> Void
    @ObservationIgnored private let saveVocabulary: ([VocabularyWord]) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let saveRemovesFillerWords: (Bool) -> Void
    @ObservationIgnored private let saveWritesNumbersAsDigits: (Bool) -> Void
    @ObservationIgnored private var accessCheckTask: Task<Void, Never>?
    @ObservationIgnored private var accessObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger.pushToTalk

    /// - Parameters:
    ///   - capture: The microphone. The app passes `.live()`, tests pass fakes.
    ///   - transcription: The speech model. Tests pass fakes.
    ///   - cleanup: The cleanup model, which runs after the rule steps when it is ready.
    ///     Tests pass fakes.
    ///   - translation: The model's translations, for dictations of the translation key.
    ///     Tests pass fakes.
    ///   - voice: Speaks a translation when Speak Translation is on. Tests pass fakes.
    ///   - insert: Puts text into the frontmost app. Tests pass fakes.
    ///   - frontmostApp: The process ID of the frontmost app. Tests pass fakes.
    ///   - lidIsClosed: Whether the MacBook's lid is closed, read when a recording holds
    ///     no sound at all. Tests pass fakes.
    ///   - isTrusted: Whether Orra has Accessibility access. The app asks
    ///     AXIsProcessTrusted, whose answer can be stale, see `watchAccess()`. Tests pass
    ///     fakes.
    ///   - installTap: Creates the keyboard tap, see `HotkeyTap.Install`. Tests pass fakes,
    ///     so they never install a real tap.
    ///   - maximumRecordingDuration: A hold longer than this is processed as if the key
    ///     had been released.
    ///   - minimumHold: Holds shorter than this are discarded.
    ///   - releaseTail: How long recording goes on after the talk key is released.
    ///   - accessCheckDelay: How long Orra waits before it checks access again, see
    ///     `watchAccess()`.
    ///   - listeningCueDelay: How long a hold lasts before the indicator shows and the
    ///     start sound plays. A shortcut with the talk key is over sooner.
    ///   - soundWaitLimit: How long after the microphone started the cue waits for sound
    ///     from it, see `scheduleListeningCue(after:hold:)`.
    ///   - talkKey: The key that starts a dictation, as saved by the user.
    ///   - saveTalkKey: Saves the key after the user changes it.
    ///   - talkKeyChosen: Whether the user has saved a talk key before.
    ///   - translationKey: The translation key, as saved, or nil for the default next to
    ///     the talk key, see `TalkKey.defaultTranslationKey(talkKey:)`.
    ///   - saveTranslationKey: Saves the translation key after it changes.
    ///   - secondTalkKey: The second talk key, as saved, or nil. One that is the talk key or
    ///     the translation key is dropped.
    ///   - saveSecondTalkKey: Saves the second talk key after it changes.
    ///   - talkMode: How the talk key starts a dictation, as saved.
    ///   - translationMode: How the translation key starts a dictation, as saved.
    ///   - saveTriggerMode: Saves the mode of a key after the user changes it.
    ///   - handsFree: Whether a double press starts a hands free dictation, as saved.
    ///   - saveHandsFree: Saves the choice after the user changes it.
    ///   - microphone: The microphone the user chose, or nil for the system default.
    ///   - saveMicrophone: Saves the choice after the user changes it.
    ///   - vocabulary: The user's words and names, as saved.
    ///   - saveVocabulary: Saves the words after they change.
    ///   - removesFillerWords: Whether fillers are removed, as saved.
    ///   - saveRemovesFillerWords: Saves the choice after the user changes it.
    ///   - writesNumbersAsDigits: Whether spoken numbers become digits, as saved.
    ///   - saveWritesNumbersAsDigits: Saves the choice after the user changes it.
    ///   - now: The time, for the dates of the vocabulary. Tests pass fakes.
    init(
        capture: AudioCapture,
        transcription: Transcription,
        cleanup: CleanupModel = .off,
        translation: TranslationModel = .off,
        voice: TranslationVoice = .off,
        insert: @escaping @MainActor (String) async -> InsertionResult,
        frontmostApp: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        lidIsClosed: @escaping @MainActor () -> Bool = { Lid.isClosed() },
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        installTap: @escaping HotkeyTap.Install = HotkeyTap.installLive,
        maximumRecordingDuration: Duration = RecordingLimits.maximumDuration,
        minimumHold: Duration = RecordingLimits.minimumHold,
        releaseTail: Duration = RecordingLimits.releaseTail,
        accessCheckDelay: Duration = .seconds(2),
        listeningCueDelay: Duration = .milliseconds(150),
        soundWaitLimit: Duration = .seconds(1),
        talkKey: Hotkey = Hotkey.defaultKey,
        saveTalkKey: @escaping (Hotkey) -> Void = { _ in },
        talkKeyChosen: Bool = false,
        translationKey: Hotkey? = nil,
        saveTranslationKey: @escaping (Hotkey) -> Void = { _ in },
        secondTalkKey: TalkKey? = nil,
        saveSecondTalkKey: @escaping (TalkKey?) -> Void = { _ in },
        talkMode: TriggerMode = .defaultMode,
        translationMode: TriggerMode = .defaultMode,
        saveTriggerMode: @escaping (TriggerMode, KeySlot) -> Void = { _, _ in },
        handsFree: Bool = true,
        saveHandsFree: @escaping (Bool) -> Void = { _ in },
        microphone: MicrophoneChoice? = nil,
        saveMicrophone: @escaping (MicrophoneChoice?) -> Void = { _ in },
        vocabulary: [VocabularyWord] = [],
        saveVocabulary: @escaping ([VocabularyWord]) -> Void = { _ in },
        removesFillerWords: Bool = true,
        saveRemovesFillerWords: @escaping (Bool) -> Void = { _ in },
        writesNumbersAsDigits: Bool = true,
        saveWritesNumbersAsDigits: @escaping (Bool) -> Void = { _ in },
        now: @escaping () -> Date = { Date() }
    ) {
        self.capture = capture
        self.transcription = transcription
        self.cleanup = cleanup
        self.translation = translation
        self.voice = voice
        self.insert = insert
        self.frontmostApp = frontmostApp
        self.lidIsClosed = lidIsClosed
        self.isTrusted = isTrusted
        self.installTap = installTap
        self.maximumRecordingDuration = maximumRecordingDuration
        self.minimumHold = minimumHold
        self.releaseTail = releaseTail
        self.accessCheckDelay = accessCheckDelay
        self.listeningCueDelay = listeningCueDelay
        self.soundWaitLimit = soundWaitLimit
        self.talkKey = talkKey
        self.saveTalkKey = saveTalkKey
        self.hasChosenTalkKey = talkKeyChosen
        let translationKey = translationKey.flatMap { $0 == talkKey ? nil : $0 } ?? Hotkey.defaultTranslationKey(talkKey: talkKey)
        self.translationKey = translationKey
        self.saveTranslationKey = saveTranslationKey
        self.secondTalkKey = secondTalkKey.flatMap {
            SecondTalkKey.isAllowed($0, talkKey: talkKey, translationKey: translationKey) ? $0 : nil
        }
        self.saveSecondTalkKey = saveSecondTalkKey
        self.talkMode = talkMode
        self.translationMode = translationMode
        self.saveTriggerMode = saveTriggerMode
        self.handsFreeOn = handsFree
        self.saveHandsFree = saveHandsFree
        self.microphone = microphone
        self.saveMicrophone = saveMicrophone
        self.vocabulary = vocabulary
        self.saveVocabulary = saveVocabulary
        self.removesFillerWords = removesFillerWords
        self.saveRemovesFillerWords = saveRemovesFillerWords
        self.writesNumbersAsDigits = writesNumbersAsDigits
        self.saveWritesNumbersAsDigits = saveWritesNumbersAsDigits
        self.now = now
    }

    /// Starts watching for the hotkey. Without Accessibility access it waits: the welcome
    /// window and the menu offer the system prompt, and the tap is installed once access
    /// is granted. The speech model loads once ModelInstaller has it in place, see
    /// AppDelegate.
    func start() {
        guard tap == nil else { return }
        microphoneAccess = capture.access()
        tap = HotkeyTap(keys: watchedKeys, delayedKeys: delayedKeys, modes: modes, handsFree: handsFreeOn, install: installTap) { [weak self] event in
            self?.handle(event, key: self?.tap?.activeKey)
        } onSwitchedOff: { [weak self] reason in
            self?.tapWasSwitchedOff(reason)
        }
        syncTapWithAccess()
        if !isHotkeyActive {
            logger.info("Waiting for Accessibility access")
        }
        watchAccess()
    }

    /// Loads the speech model, and again after a failed load, for example once the model
    /// files are in place again. Does nothing while loading or once loaded. ModelInstaller
    /// calls it through AppDelegate whenever the model is installed. Internal so tests can
    /// drive it.
    func loadModel() async {
        switch modelState {
        case .loading, .ready:
            return
        case .notLoaded, .unavailable:
            break
        }
        modelState = .loading
        let started = ContinuousClock.now
        // Reserves the model gate, so the speech model loads ahead of a voice model that
        // waits, also at launch, see ModelGate.reserve.
        let reservation = transcription.gate?.reserve()
        defer { reservation?.end() }
        do {
            try await transcription.load()
            modelState = .ready
            // Notice rather than info, so it stays in the log store, where the launch check
            // in docs/manual-testing.md reads it.
            logger.notice("Speech model loaded in \(started.duration(to: .now), privacy: .public)")
        } catch TranscriptionError.modelMissing {
            modelState = .unavailable(.missing)
        } catch {
            modelState = .unavailable(.failedToLoad)
            logger.error("Speech model failed to load: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces the vocabulary for the next dictations and saves it.
    func setVocabulary(_ words: [VocabularyWord]) {
        guard words != vocabulary else { return }
        vocabulary = words
        saveVocabulary(words)
    }

    /// Adds a word, typed, copied or learned, dated now. Refused only at the sanity cap,
    /// `Vocabulary.maximumCount`. An empty word adds nothing and counts as already there.
    @discardableResult
    func addToVocabulary(_ term: String, source: VocabularyWord.Source = .user) -> VocabularyAddition {
        guard let word = Vocabulary.cleaned(term), !Vocabulary.contains(word, in: vocabulary) else {
            return .alreadyThere
        }
        guard vocabulary.count < Vocabulary.maximumCount else { return .full }
        setVocabulary(Vocabulary.adding(word, to: vocabulary, at: now(), source: source))
        return .added
    }

    /// Takes the words out of the vocabulary, ignoring case.
    func removeFromVocabulary(_ terms: some Sequence<String>) {
        setVocabulary(Vocabulary.removing(terms, from: vocabulary))
    }

    /// Whether the vocabulary holds the word, ignoring case.
    func vocabularyContains(_ term: String) -> Bool {
        Vocabulary.contains(term, in: vocabulary)
    }

    /// Dates the last use of the words a pasted transcript holds. Keeps no text.
    private func markVocabularyUsed(in text: String) {
        guard !vocabulary.isEmpty else { return }
        setVocabulary(Vocabulary.markingUsed(in: text, vocabulary, at: now()))
    }

    /// Turns filler removal on or off for the next dictations and saves the choice.
    func setRemovesFillerWords(_ on: Bool) {
        guard on != removesFillerWords else { return }
        removesFillerWords = on
        saveRemovesFillerWords(on)
    }

    /// Turns writing spoken numbers as digits on or off for the next dictations and saves
    /// the choice.
    func setWritesNumbersAsDigits(_ on: Bool) {
        guard on != writesNumbersAsDigits else { return }
        writesNumbersAsDigits = on
        saveWritesNumbersAsDigits(on)
    }

    /// Chooses the microphone for the next dictations, or the system default for nil, and
    /// saves the choice. What the microphone kept for the choice before goes now, not at
    /// the next press.
    func setMicrophone(_ choice: MicrophoneChoice?) {
        guard choice != microphone else { return }
        microphone = choice
        saveMicrophone(choice)
        Task { [capture] in
            await capture.microphoneChosen(choice?.uid)
        }
    }

    /// Makes `key` the talk key and saves the choice. Saved even when it is the key in use
    /// already, such as the default, so the welcome window counts the step as done on the
    /// next launch too. When `key` is the translation key, the translation key becomes the
    /// old talk key and `keySwap` says so. When `key` is the second talk key, the two talk
    /// keys swap, or the second key goes when the old talk key is a combination.
    func chooseTalkKey(_ key: Hotkey) {
        hasChosenTalkKey = true
        keySwap = nil
        let oldTalkKey = talkKey
        if key == translationKey, key != talkKey {
            translationKey = talkKey
            saveTranslationKey(talkKey)
            keySwap = KeySwap(talkKey: key, translationKey: translationKey)
        }
        talkKey = key
        saveTalkKey(key)
        if let secondTalkKey, !SecondTalkKey.isAllowed(secondTalkKey, talkKey: talkKey, translationKey: translationKey) {
            setSecondTalkKey(oldTalkKey.single.flatMap { SecondTalkKey.isAllowed($0, talkKey: talkKey, translationKey: translationKey) ? $0 : nil })
        }
        updateTapKeys()
    }

    /// Makes `key` the translation key and saves the choice. When `key` is the talk key,
    /// the talk key becomes the old translation key and `keySwap` says so.
    func chooseTranslationKey(_ key: Hotkey) {
        keySwap = nil
        if key == talkKey, key != translationKey {
            talkKey = translationKey
            hasChosenTalkKey = true
            saveTalkKey(talkKey)
            keySwap = KeySwap(talkKey: talkKey, translationKey: key)
        }
        translationKey = key
        saveTranslationKey(key)
        // The translation key takes the second talk key's key away from it.
        if let secondTalkKey, !SecondTalkKey.isAllowed(secondTalkKey, talkKey: talkKey, translationKey: translationKey) {
            setSecondTalkKey(nil)
        }
        updateTapKeys()
    }

    /// The keys the second talk key can be now, see SecondTalkKey.
    var secondTalkKeyChoices: [TalkKey] {
        SecondTalkKey.choices(talkKey: talkKey, translationKey: translationKey)
    }

    /// Makes `key` the second talk key, or removes it for nil, and saves the choice. A key
    /// that is the talk key or the translation key changes nothing.
    func setSecondTalkKey(_ key: TalkKey?) {
        guard key != secondTalkKey else { return }
        if let key, !SecondTalkKey.isAllowed(key, talkKey: talkKey, translationKey: translationKey) { return }
        secondTalkKey = key
        saveSecondTalkKey(key)
        updateTapKeys()
    }

    /// Starts or stops watching the translation key, when translation is turned on or off.
    /// Turning it off ends a dictation the translation key started, as a change of keys
    /// does.
    func setTranslationKeyOn(_ on: Bool) {
        guard on != translationKeyIsOn else { return }
        translationKeyIsOn = on
        updateTapKeys()
    }

    /// Sets how the key of `slot` starts a dictation and saves the choice.
    func setTriggerMode(_ mode: TriggerMode, for slot: KeySlot) {
        switch slot {
        case .talk:
            guard mode != talkMode else { return }
            talkMode = mode
        case .translation:
            guard mode != translationMode else { return }
            translationMode = mode
        }
        saveTriggerMode(mode, slot)
        updateTapKeys()
    }

    /// The hint for the talk key in its mode, such as "Hold right Control to talk", or
    /// "Hold fn or right Control to talk" with a second talk key.
    func talkHint(in locale: Locale = .interface) -> String {
        talkKey.talkHint(mode: talkMode, secondKey: secondTalkKey, in: locale)
    }

    /// The hint for the translation key in its mode, such as "Hold right Option to
    /// translate".
    func translateHint(in locale: Locale = .interface) -> String {
        translationKey.translateHint(mode: translationMode, in: locale)
    }

    /// Whether double press for hands free does anything: a watched key is in hold mode.
    var handsFreeApplies: Bool {
        talkMode == .hold || (translationKeyIsOn && translationMode == .hold)
    }

    /// The second talk key as a hotkey, or nil.
    private var secondTalkHotkey: Hotkey? {
        secondTalkKey.map(Hotkey.key)
    }

    /// The keys the tap watches: the talk key, the second talk key when there is one, and the
    /// translation key while translation is on.
    private var watchedKeys: Set<Hotkey> {
        var keys: Set<Hotkey> = [talkKey]
        if let secondTalkHotkey {
            keys.insert(secondTalkHotkey)
        }
        if translationKeyIsOn {
            keys.insert(translationKey)
        }
        return keys
    }

    /// The translation key waits before its press counts, as a left hand key does, so
    /// Option shortcuts and the characters right Option types keep working. A combination
    /// with a regular key is hidden from apps and needs no wait. The talk key and the second
    /// talk key do not wait, unless one is a modifier of another watched key's combination,
    /// such as right Control beside Control and Option, so the combination can take over
    /// within the wait. A right hand key or fn among these records from its key down while
    /// it waits, see `TalkKeyDetector.capturesEarly(_:)`.
    private var delayedKeys: Set<Hotkey> {
        let watched = watchedKeys
        var keys: Set<Hotkey> = translationKeyIsOn && !translationKey.hasRegularKey ? [translationKey] : []
        for key in watched where key.single != nil {
            for other in watched where other != key {
                if let combination = other.combination, combination.keyCode == nil,
                   combination.modifiers.isSuperset(of: key.modifiers) {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    /// The second talk key works in the talk key's mode.
    private var modes: [Hotkey: TriggerMode] {
        var modes = [talkKey: talkMode]
        if let secondTalkHotkey {
            modes[secondTalkHotkey] = talkMode
        }
        if translationKeyIsOn {
            modes[translationKey] = translationMode
        }
        return modes
    }

    private func updateTapKeys() {
        tap?.setKeys(watchedKeys, delayedKeys: delayedKeys, modes: modes)
    }

    /// Turns double press for hands free on or off and saves the choice.
    func setHandsFreeOn(_ on: Bool) {
        guard on != handsFreeOn else { return }
        handsFreeOn = on
        saveHandsFree(on)
        tap?.setHandsFree(on)
    }

    /// Starts recording the key the user wants for `slot`, see KeyRecorder. A key that can
    /// be a talk key, pressed and released on its own, becomes the key. Anything else
    /// leaves a note and the recording goes on. Escape, a click anywhere in Orra, or
    /// switching to another app stops it. Only presses in Orra count: the tap checks that
    /// Orra is the active app, and without the tap a local monitor sees only Orra's own
    /// events. Neither needs a new permission. A recording for the other slot stops first.
    func startChoosingKey(for slot: KeySlot) {
        guard choosingKeySlot != slot else { return }
        stopChoosingKey()
        choosingKeySlot = slot
        keyChoiceRejection = nil
        keySwap = nil
        keyRecorder = KeyRecorder()
        tap?.chooseKey { [weak self] type, keyCode, flags in
            self?.keyChoice(type: type, keyCode: keyCode, flags: flags)
        }
        keyChoiceMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                // The tap has seen the event first when it is installed.
                guard let self, choosingKeySlot != nil, tap?.isInstalled != true else { return event }
                let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                let type: CGEventType = event.type == .keyDown ? .keyDown : .flagsChanged
                keyChoice(type: type, keyCode: Int64(event.keyCode), flags: flags)
                // As the tap does: a key pressed to record types nothing, and Escape does
                // not close the window.
                return type == .keyDown ? nil : event
            },
            // A click anywhere in Orra ends the recording, as in the shortcut recorders of
            // Mac apps. The click itself goes on to what was clicked.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.stopChoosingKey()
                return event
            },
        ].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopChoosingKey()
            }
        }
    }

    /// Stops recording a key without changing it.
    func stopChoosingKey() {
        guard choosingKeySlot != nil else { return }
        choosingKeySlot = nil
        keyChoiceRejection = nil
        tap?.chooseKey(nil)
        keyChoiceMonitors.forEach(NSEvent.removeMonitor)
        keyChoiceMonitors = []
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }

    /// One key down or flags changed event while the user records a key. Internal so tests
    /// can drive it.
    func keyChoice(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        guard let slot = choosingKeySlot else { return }
        guard let outcome = keyRecorder.handle(type: type, keyCode: keyCode, flags: flags) else {
            // A key that can be the talk key is down, so the note about an earlier press
            // no longer applies.
            if keyRecorder.isPending {
                keyChoiceRejection = nil
            }
            return
        }
        switch outcome {
        case .chosen(var key):
            stopChoosingKey()
            // The name of a regular key depends on the keyboard layout, so it is kept as it
            // looks now.
            if let combination = key.combination, let code = combination.keyCode, KeyName.namedKey(code) == nil {
                key = .combination(KeyCombination(modifiers: combination.modifiers, keyCode: code, character: KeyName.character(forKeyCode: code)))
            }
            switch slot {
            case .talk: chooseTalkKey(key)
            case .translation: chooseTranslationKey(key)
            }
        case .rejected(let rejection):
            keyChoiceRejection = rejection
        case .cancelled:
            stopChoosingKey()
        }
    }

    /// The key that finishes the hands free dictation in progress, for the indicator: the
    /// key that started it, or the talk key.
    private var handsFreeKey: Hotkey {
        tap?.activeKey ?? talkKey
    }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility.
    func promptForAccessibility() {
        // The key is the value of kAXTrustedCheckOptionPrompt. Swift 6 rejects
        // reading that C global because it is imported as a mutable variable,
        // so the string is spelled out. Its value was checked on macOS 26.6.2.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for microphone access when the user has not decided yet, or opens the
    /// microphone pane of System Settings when access is off.
    func requestMicrophoneAccess() {
        switch capture.access() {
        case .notDetermined:
            Task { [weak self] in
                guard let self else { return }
                microphoneAccess = await capture.requestAccess()
            }
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .authorized, .notConfigured:
            microphoneAccess = capture.access()
        }
    }

    /// Applies one push to talk event. `key` is the key the event is about, which tells a
    /// dictation of the translation key from one of the talk key. Internal so tests can
    /// drive it.
    func handle(_ event: PushToTalkStateMachine.Event, key: Hotkey? = nil) {
        // The tap keeps Escape and the next press for a hands free dictation only while one
        // runs. It may have ended here some other way, or never started.
        defer {
            if machine.state != .handsFree {
                tap?.endHandsFree()
            }
        }
        guard let transition = machine.handle(event) else { return }
        state = machine.state
        logger.debug("Push to talk transition: \(String(describing: transition), privacy: .public)")
        switch transition {
        case .startedListening, .startedHandsFree, .resumedListening, .confirmedArming:
            // The direction is read once, so the indicator and the paste agree.
            holdTranslation = translationKeyIsOn && key == translationKey ? translation.direction() : nil
        default:
            break
        }
        switch transition {
        case .startedArming:
            // A press that may still be a shortcut starts the microphone silently, so the
            // recording starts at the key down once the press counts. Nothing here may show,
            // say or load anything. When the microphone cannot start silently, the press
            // starts it once it counts, and says then why it cannot.
            holdMessage = nil
            indicatorShown = false
            captureStart = nil
            guard !isRecordingVoiceSample, modelState == .ready, capture.access() == .authorized else {
                handle(.cancelled)
                return
            }
            startCapture()
        case .confirmedArming:
            clearHoldNotes()
            let counted = ContinuousClock.now
            holdTimings?.counted = counted
            beginUserActivity()
            reserveModelGate()
            cleanup.dictationStarted()
            // The delay counts from the key down, which the wait has used up already.
            let held = holdTimings.map { $0.keyDown.duration(to: counted) } ?? .zero
            scheduleListeningCue(after: state == .listening ? max(.zero, listeningCueDelay - held) : .zero, hold: holdNumber)
        case .droppedArming:
            // A shortcut, or a press too short to count: no cue, no sound and no message.
            recordingLimitTask?.cancel()
            listeningCueTask?.cancel()
            cancelCapture(logsTimings: false)
        case .startedListening, .startedHandsFree:
            clearHoldNotes()
            holdMessage = nil
            indicatorShown = false
            // The previous hold's start belongs to that hold only.
            captureStart = nil
            guard !isRecordingVoiceSample else {
                holdMessage = String(localized: "Orra is recording a voice sample in Settings")
                handle(.cancelled)
                return
            }
            guard modelState == .ready else {
                // The menu bar icon and the menu say why too.
                holdMessage = Self.notReadyMessage(modelState)
                handle(.cancelled)
                return
            }
            reserveModelGate()
            // Loads the model when it was unloaded while idle, so it loads while the user
            // speaks, for cleanup and for translation.
            cleanup.dictationStarted()
            startRecording(cueDelay: transition == .startedHandsFree ? .zero : listeningCueDelay)
        case .awaitingSecondPress:
            // The recording goes on until the second press or the end of the window.
            break
        case .resumedListening:
            // The second press after a tap. The recording goes on. If the press turns out
            // to be a hold, its cue comes like any hold's. A double press replaces it with
            // the hands free cue at the release.
            listeningCueTask?.cancel()
            scheduleListeningCue(after: listeningCueDelay, hold: holdNumber)
        case .switchedToHandsFree:
            listeningCueTask?.cancel()
            scheduleListeningCue(after: .zero, hold: holdNumber)
        case .startedProcessing:
            recordingLimitTask?.cancel()
            listeningCueTask?.cancel()
            let released = ContinuousClock.now
            let heldFor = holdTimings?.counted.map { $0.duration(to: released) } ?? .zero
            if heldFor >= minimumHold {
                indicatorShown = true
                onCue(.transcribing)
            } else {
                // Cleared at once, because a slow microphone can take seconds to stop.
                endCue(nil)
            }
            let target = frontmostApp()
            let start = captureStart
            let chosen = holdMicrophone
            let translating = holdTranslation
            let captureTimings = holdTimings
            Task { [weak self] in
                await self?.finishRecording(start: start, chosen: chosen, heldFor: heldFor, target: target, translating: translating, releasedAt: released)
                // After the paste, because the microphone gets ready for the next hold once
                // it stopped, and reading how it started waits for that.
                if let startedAt = await start?.value {
                    await self?.logCaptureTimings(captureTimings, startedAt: startedAt)
                }
                self?.handle(.processingFinished)
            }
        case .cancelledListening:
            recordingLimitTask?.cancel()
            listeningCueTask?.cancel()
            endUserActivity()
            cancelCapture(logsTimings: true)
            endCue(holdMessage ?? problem)
            cleanup.dictationEnded()
            endModelGateReservation()
        case .finished:
            endUserActivity()
            endCue(holdMessage ?? problem ?? notice)
            cleanup.dictationEnded()
            endModelGateReservation()
        }
    }

    /// Clears what the menu showed about the last hold, once a new one starts.
    private func clearHoldNotes() {
        problem = nil
        notice = nil
        microphoneNotice = nil
        suggestsSoundSettings = false
    }

    /// Stops the microphone after a hold that ends without processing, and logs how it
    /// started when `logsTimings` is true. Waits for the cancel before, so cancels and
    /// starts reach the microphone in the order of the holds. A start that has not begun
    /// yet is skipped, see `startCapture()`.
    private func cancelCapture(logsTimings: Bool) {
        let start = captureStart
        start?.cancel()
        let previous = captureCancel
        let timings = logsTimings ? holdTimings : nil
        captureCancel = Task { [weak self, capture] in
            await previous?.value
            guard let started = await start?.value else { return }
            await capture.cancel()
            await self?.logCaptureTimings(timings, startedAt: started)
        }
    }

    /// One line per hold whose microphone started, nothing when `timings` is nil. Notice
    /// rather than info, so it stays in the log store, where Report a Problem reads it.
    /// Numbers only.
    private func logCaptureTimings(_ timings: CaptureTimings?, startedAt: ContinuousClock.Instant) async {
        guard var timings else { return }
        timings.startReturned = startedAt
        timings.onset = await capture.onset()
        logger.notice("Capture start: \(timings.summary, privacy: .public)")
    }

    /// Ends the hold for the indicator: shows the message when there is one, and otherwise
    /// clears the indicator if this hold showed it. A hold that showed nothing, such as a
    /// shortcut, leaves an earlier message alone.
    private func endCue(_ message: String?) {
        if let message {
            onCue(.finished(message: message))
        } else if indicatorShown {
            onCue(.finished(message: nil))
        }
        indicatorShown = false
    }

    /// The peak of the latest audio while recording, from 0 to 1, for the indicator.
    func inputLevel() -> Float {
        capture.level()
    }

    /// Reads microphone permission again, for the welcome window while the user may be
    /// changing it in System Settings. Reading never shows a prompt.
    func refreshMicrophoneAccess() {
        let access = capture.access()
        if access != microphoneAccess {
            microphoneAccess = access
        }
    }

    /// Why a hold cannot record while the speech model is not ready.
    private static func notReadyMessage(_ state: ModelState) -> String {
        switch state {
        case .notLoaded, .ready:
            String(localized: "The speech model is not ready. The Orra menu shows what is missing.")
        case .loading:
            String(localized: "The speech model is still loading")
        case .unavailable(let problem):
            problem.message()
        }
    }

    /// True while Orra tells macOS that a dictation is in progress. Internal for tests.
    var isKeepingDictationAwake: Bool {
        userActivity != nil
    }

    private func beginUserActivity() {
        guard userActivity == nil else { return }
        userActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recording and transcribing a dictation")
    }

    private func endUserActivity() {
        if let userActivity {
            ProcessInfo.processInfo.endActivity(userActivity)
        }
        userActivity = nil
    }

    private func reserveModelGate() {
        guard gateReservation == nil else { return }
        gateReservation = transcription.gate?.reserve()
    }

    private func endModelGateReservation() {
        gateReservation?.end()
        gateReservation = nil
    }

    /// Starts the microphone for a hold, or ends the hold when that is not possible.
    /// The first hold asks for microphone access and is cancelled, because the prompt
    /// takes the focus while the talk key is still down.
    private func startRecording(cueDelay: Duration) {
        microphoneAccess = capture.access()
        switch microphoneAccess {
        case .authorized:
            let counted = ContinuousClock.now
            beginUserActivity()
            startCapture()
            holdTimings?.counted = counted
            scheduleListeningCue(after: cueDelay, hold: holdNumber)
        case .notDetermined:
            // The system prompt that follows says enough.
            handle(.cancelled)
            requestMicrophoneAccess()
        case .denied:
            holdMessage = String(localized: "Microphone access is off")
            handle(.cancelled)
        case .notConfigured:
            holdMessage = String(localized: "This build has no microphone usage description")
            handle(.cancelled)
        }
    }

    /// Starts the microphone off the main thread and the recording limit, and shows and says
    /// nothing, so a press that has not counted yet can start it too.
    private func startCapture() {
        // From the key down when the tap saw it, so the log covers the wait of a key too.
        let press = tap?.press
        holdTimings = CaptureTimings(keyDown: press?.keyDown ?? .now, waited: press?.waited ?? false)
        holdNumber += 1
        let hold = holdNumber
        let previousCancel = captureCancel
        let chosen = microphone
        holdMicrophone = chosen
        // The hardware starts off the main thread, so the key event is answered at once.
        // A cancelled hold may still be stopping the microphone, so that goes first.
        captureStart = Task { [weak self, capture] in
            await previousCancel?.value
            // A hold that ended meanwhile, such as a shortcut typed while a slow microphone
            // still started for the press before, needs no microphone. Its cancel then
            // has nothing to stop, so the next hold waits only for starts already begun.
            guard !Task.isCancelled else { return nil }
            do {
                try await capture.start(chosen?.uid)
                return ContinuousClock.now
            } catch {
                self?.recordingFailedToStart(error, hold: hold, chosen: chosen)
                return nil
            }
        }
        recordingLimitTask = Task { [weak self, maximumRecordingDuration] in
            try? await Task.sleep(for: maximumRecordingDuration)
            guard !Task.isCancelled, let self, state == .listening || state == .handsFree else { return }
            logger.info("Recording reached its maximum length")
            // The audio buffer holds no more, so the dictation ends here and says why.
            notice = String(localized: "Orra records up to 1 minute at a time, so the recording stopped there.")
            handle(.released)
        }
    }

    /// Sends the listening cue, or the hands free cue, once `delay` has passed and the
    /// microphone has delivered sound, if the hold is still the current one and still
    /// records.
    ///
    /// The wait for sound covers a microphone that takes a while to start, which took
    /// 0.3 s for a USB microphone, and one that delivers zeros after it started, as a
    /// Bluetooth one is reported to do for about half a second. So whoever starts talking
    /// at the sound is recorded from the first syllable. A microphone that sends no sound
    /// within `soundWaitLimit` after it started gets the cue anyway, so nobody is left
    /// waiting, and its hold ends with the message about the silence as before. One second
    /// is twice that reported Bluetooth delay, so a working microphone has sent sound by
    /// then. A microphone that fails to start sends no cue.
    private func scheduleListeningCue(after delay: Duration, hold: Int) {
        let started = captureStart
        listeningCueTask = Task { [weak self, capture, soundWaitLimit] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let startedAt = await started?.value else { return }
            await capture.waitForSound(startedAt + soundWaitLimit)
            guard !Task.isCancelled, let self, holdNumber == hold else { return }
            switch state {
            case .listening:
                indicatorShown = true
                onCue(.listening(translation: holdTranslation))
            case .handsFree:
                indicatorShown = true
                onCue(.handsFree(finishHint: handsFreeKey.finishHint(), translation: holdTranslation))
            case .idle, .arming, .waitingForSecondPress, .processing:
                break
            }
        }
    }

    private func recordingFailedToStart(_ error: any Error, hold: Int, chosen: MicrophoneChoice?) {
        logger.error("Could not start recording: \(String(describing: error), privacy: .public)")
        // A newer hold has started since. This one was cancelled and nobody waits for it.
        guard hold == holdNumber else { return }
        // A press that has not counted says nothing, also when a shortcut dropped it before
        // the start failed. Once a press counts, it starts the microphone again and says
        // then what went wrong.
        guard holdCounted else {
            if machine.state == .arming {
                handle(.cancelled)
            }
            return
        }
        if case AudioRecorderError.inputUnitFailed = error, let chosen {
            problem = String(localized: "\(chosen.name) could not start")
            // System Default records another way, so it is the way out. With the lid
            // closed the default can be the internal microphone, so the device has to be
            // picked in Sound settings too.
            microphoneNotice = String(localized: "Choose System Default under Microphone, then pick \(chosen.name) in Sound settings.")
            suggestsSoundSettings = true
        } else {
            problem = String(localized: "The microphone could not start")
        }
        if machine.isRecording {
            handle(.cancelled)
        }
    }

    /// Ends a hold that was released: waits for the microphone to have started, records
    /// the short tail, stops, and transcribes unless the hold was too short or cut.
    /// `translating` is the direction when the translation key started the dictation.
    private func finishRecording(start: Task<ContinuousClock.Instant?, Never>?, chosen: MicrophoneChoice?, heldFor: Duration, target: pid_t?, translating: TranslationDirection?, releasedAt released: ContinuousClock.Instant) async {
        var timings = DictationTimings(releasedAt: released)
        // A failed start already set the problem.
        guard await start?.value != nil else { return }
        timings.lap(.start)
        if releaseTail > .zero {
            try? await Task.sleep(for: releaseTail)
        }
        timings.lap(.releaseTail)
        let recording = await capture.stop()
        timings.lap(.microphoneStop)
        if recording.wasCut {
            problem = String(localized: "The microphone changed during the recording. Try again.")
            return
        }
        guard heldFor >= minimumHold else {
            logger.debug("Hold too short, recording discarded")
            return
        }
        onCue(.recordingStopped)
        if let chosen, recording.input?.uid != chosen.uid {
            // The chosen microphone was not connected, so the system default recorded.
            // Logged here, once for a dictation, rather than at each start, which a
            // shortcut during the wait of a key makes too.
            logger.notice("The chosen microphone was not connected, so the system default input recorded")
            if let name = recording.input?.name {
                microphoneNotice = String(localized: "\(chosen.name) is not connected, so \(name) recorded.")
            } else {
                microphoneNotice = String(localized: "\(chosen.name) is not connected, so the system default input recorded.")
            }
        }
        await transcribeAndInsert(recording, chosen: chosen, target: target, translating: translating, timings: &timings)
    }

    /// Turns a recording into text and pastes it, translated when `translating` is set and
    /// the translation passes its checks. Logs timings, never the text. `timings` gets the
    /// time of each step.
    private func transcribeAndInsert(_ recording: AudioRecording, chosen: MicrophoneChoice?, target: pid_t?, translating: TranslationDirection?, timings: inout DictationTimings) async {
        do {
            let (samples, silent) = await Self.prepared(recording)
            timings.lap(.resampling)
            guard !samples.isEmpty else {
                problem = String(localized: "The recording could not be transcribed")
                logger.error("No samples after resampling \(recording.samples.count, privacy: .public) recorded samples")
                return
            }
            if silent {
                // The microphone delivered zeros, so there is nothing to transcribe. Say why
                // instead of doing nothing.
                let situation = MicrophoneSituation(lidClosed: lidIsClosed(), input: recording.input)
                problem = Silence.advice(for: situation)
                if let chosen, recording.input?.uid == chosen.uid {
                    // The chosen microphone records whatever input Sound settings names, so
                    // the way out is Orra's own choice.
                    microphoneNotice = String(localized: "\(chosen.name) is chosen under Microphone. Choose another microphone or System Default there.")
                } else {
                    suggestsSoundSettings = true
                }
                logger.notice("The microphone delivered no sound for \(recording.duration, privacy: .public) s, lid closed: \(situation.lidClosed, privacy: .public)")
                return
            }
            let raw = try await transcription.transcribe(
                samples,
                vocabulary: Vocabulary.forModel(vocabulary),
                audioSeconds: recording.duration,
                takingDigits: writesNumbersAsDigits
            )
            timings.lap(.recognition)
            var text = ChineseText.simplified(TranscriptGuard.clean(raw, audioSeconds: recording.duration))
            // The text as heard, before the filler rule, for the cleanup gate: a filler
            // cue the rule removed still asks for the model.
            let heard = text
            timings.lap(.transcriptGuard)
            if removesFillerWords {
                text = FillerRules.removingFillers(from: text)
            }
            timings.lap(.fillers)
            if writesNumbersAsDigits {
                text = NumberRules.writingNumbersAsDigits(in: text)
            }
            timings.lap(.numbers)
            // The user's words go in after the rule steps, which learning saw the heard
            // spellings after, so no rule rewrites a user's word, and before the cleanup
            // model, so it sees them.
            var replacements: [Replacement] = []
            let pairs = replacementPairs()
            if !pairs.isEmpty, !text.isEmpty {
                (text, replacements) = await Self.replacingWords(in: text, pairs: pairs, vocabulary: vocabulary.map(\.text))
            }
            timings.lap(.wordReplacement)
            guard !text.isEmpty else {
                holdMessage = String(localized: "No speech was recognized")
                logger.notice("No speech recognized in \(recording.duration, privacy: .public) s of audio")
                return
            }
            // The rule steps come first, so the model sees their result, and any problem
            // with the model leaves exactly that text. A model that the press of the key
            // started to load is waited for, a bounded time.
            let ruled = text
            let step = await translate(text, translating)
            let translated = step?.result
            let language = step?.target
            timings.lap(.translation)
            if let translated {
                // In place of the cleanup step, since the translation prompt cleans up too.
                text = translated.text
            } else if CleanupStep.isWorthCleaning(text) {
                if CleanupStep.hasWorkForModel(text, heard: heard) {
                    let loaded = await cleanup.waitUntilLoaded()
                    timings.lap(.cleanupWait)
                    if loaded {
                        text = await CleanupStep.run(text, complete: cleanup.complete).text
                        timings.lap(.cleanup)
                    }
                } else {
                    // The gate found no filler or correction cue, so the model is skipped.
                    // The check still ends the cleanup step, so its time is not counted
                    // as part of the paste.
                    timings.lap(.cleanup)
                }
            }
            let isTranslation = translated?.isTranslation == true
            if isTranslation {
                originalText = translated?.untranslated
            } else {
                originalText = text == ruled ? nil : ruled
            }
            lastTranscript = text
            // Speak Translation hands a translation to the voice, which speaks it after the
            // translations before it, into the device the user chose. Only a translation:
            // one that failed is not spoken in the wrong language.
            if isTranslation, let language, voice.speaks() {
                voice.speak(text, language)
                if !voice.alsoPastes() {
                    markVocabularyUsed(in: originalText ?? text)
                    let total = timings.total
                    logger.notice("Release to speak took \(total, privacy: .public) for \(recording.duration, privacy: .public) s of audio, the translation was not pasted")
                    return
                }
            }
            // Paste only into the app that was in front when the key was released.
            if let target, let current = frontmostApp(), current != target {
                notice = String(localized: "Another app came to the front, so the text was not pasted. Use Copy Last Dictation.")
                return
            }
            switch await insert(text) {
            case .pasted:
                timings.lap(.paste)
                let pasted = timings
                // Notice rather than info, so the timing stays in the log store for later
                // checks. Numbers only.
                logger.notice("Release to paste took \(pasted.total, privacy: .public) for \(recording.duration, privacy: .public) s of audio: \(pasted.summary, privacy: .public)")
                onTimings(pasted)
                // The words are in the text before translation.
                markVocabularyUsed(in: isTranslation ? originalText ?? text : text)
                // Orra never learns from a translated paste: a fix of the translation is no
                // misheard word.
                if !isTranslation, let app = target ?? frontmostApp() {
                    onPasted(text, app, originalText, replacements)
                }
            case .skippedPasswordField:
                notice = String(localized: "Orra does not paste into password fields. Use Copy Last Dictation.")
            case .nothingToInsert:
                break
            }
        } catch {
            problem = String(localized: "The recording could not be transcribed")
            logger.error("Transcription failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Paste Original Text in the menu: pastes the latest dictation as it was before the
    /// model translated it or cleaned it up, into the frontmost app. Orra does not learn
    /// from this paste, and Copy Last Dictation still copies what was pasted first.
    func pasteOriginal() async {
        guard state == .idle, let originalText else { return }
        if let lastTranscript {
            onPasteOriginal(lastTranscript)
        }
        switch await insert(originalText) {
        case .pasted, .nothingToInsert:
            break
        case .skippedPasswordField:
            notice = String(localized: "Orra does not paste into password fields. Use Copy Last Dictation.")
        }
    }

    /// The translation of a dictation of the translation key and its target language, or
    /// nil when the translation step did not run: not a dictation of the translation key,
    /// the model not ready, also after a bounded wait for a load the press of the key
    /// started, the text too long, or nothing in it to translate, such as digits only. The
    /// step's result holds the text without translation whenever the translation cannot be
    /// used. Every case that pastes the text untranslated, other than one with nothing to
    /// translate or already in the target language, leaves a notice that says so.
    private func translate(_ text: String, _ direction: TranslationDirection?) async -> (result: TranslationStep.Result, target: TranslationTarget)? {
        guard let direction else { return nil }
        guard await translation.waitUntilLoaded() else {
            notice = String(localized: "The local model is not ready, so the text was pasted without translation.")
            return nil
        }
        guard let target = direction.target(for: text) else { return nil }
        guard text.count <= TranslationStep.maximumLength else {
            notice = String(localized: "Dictations over \(TranslationStep.maximumLength) characters are pasted without translation.")
            return nil
        }
        // The model is loaded by now, so this does not wait.
        let cleansUp = await cleanup.waitUntilLoaded()
        let result = await TranslationStep.run(text, into: target, cleansUp: cleansUp, complete: translation.complete)
        switch result.outcome {
        case .translated, .unchanged:
            break
        case .unreadable, .heldBack, .timedOut, .failed:
            notice = String(localized: "This dictation was pasted without translation.")
        }
        return (result, target)
    }

    /// Off the main actor, since the first use reads the word lists, see OrdinaryWords.
    @concurrent
    nonisolated private static func replacingWords(in text: String, pairs: [Correction], vocabulary: [String]) async -> (String, [Replacement]) {
        let result = WordReplacement.apply(to: text, pairs: pairs, vocabulary: vocabulary, ordinary: .system)
        return (result.text, result.replacements)
    }

    /// Starts the microphone chosen in Orra for a voice sample in Settings, the way a hold
    /// starts it, so the microphone access the user gave covers it. Throws while a
    /// dictation runs, without microphone access, or when the microphone could not start.
    func startVoiceSample() async throws {
        guard state == .idle, !isRecordingVoiceSample, capture.access() == .authorized else {
            throw VoiceSampleCaptureError.busy
        }
        isRecordingVoiceSample = true
        // A cancelled hold may still be stopping the microphone.
        await captureCancel?.value
        do {
            try await capture.start(microphone?.uid)
        } catch {
            isRecordingVoiceSample = false
            throw error
        }
        logger.notice("Recording a voice sample")
    }

    /// Stops the voice sample's recording and returns it. Logs its length only.
    func stopVoiceSample() async -> AudioRecording {
        guard isRecordingVoiceSample else { return AudioRecording(samples: [], sampleRate: 0) }
        let recording = await capture.stop()
        isRecordingVoiceSample = false
        logger.notice("A voice sample of \(recording.duration, format: .fixed(precision: 1), privacy: .public) s was recorded")
        return recording
    }

    /// Stops the voice sample's recording and throws it away.
    func cancelVoiceSample() async {
        guard isRecordingVoiceSample else { return }
        await capture.cancel()
        isRecordingVoiceSample = false
    }

    /// Writes down what is said in a voice sample for Speak Translation, with the speech
    /// model of dictation, which the voice model needs to imitate the voice. No vocabulary,
    /// no cleanup and no paste. Logs nothing, the caller keeps the words in memory only.
    /// Throws while the speech model is not loaded.
    func transcribeVoiceSample(_ sample: VoiceSample) async throws -> String {
        guard modelState == .ready else { throw TranscriptionError.modelMissing }
        let recording = AudioRecording(samples: sample.samples, sampleRate: Double(sample.sampleRate))
        let (samples, silent) = await Self.prepared(recording)
        guard !samples.isEmpty, !silent else { return "" }
        let raw = try await transcription.transcribe(samples, nil, nil)
        return TranscriptGuard.clean(raw, audioSeconds: recording.duration)
    }

    /// Writes down what the voice model said in a sentence of a spoken translation, for the
    /// word check of Speak Translation (SpeechWordCheck), with the speech model of
    /// dictation. The speech model is told to write `language`, the language the voice
    /// model was asked to speak, so short Chinese said in an English voice is less often
    /// written as English words (see SpeechWordCheck). With no `language` it gets no hint.
    /// No vocabulary and no guard. Logs
    /// nothing, and the caller keeps the words in memory only. Throws while the speech model
    /// is not loaded.
    func transcribeSpeech(_ audio: SpokenAudio, in language: TranslationTarget?) async throws -> String {
        guard modelState == .ready else { throw TranscriptionError.modelMissing }
        let recording = AudioRecording(samples: audio.samples, sampleRate: Double(audio.sampleRate))
        let (samples, _) = await Self.prepared(recording)
        guard !samples.isEmpty else { return "" }
        return try await transcription.transcribe(samples, nil, language.map(SpeechLanguage.init))
    }

    /// Resampling and the silence check run off the main actor, because a long recording
    /// takes a moment.
    @concurrent
    nonisolated private static func prepared(_ recording: AudioRecording) async -> (samples: [Float], silent: Bool) {
        let samples = AudioResampler.monoAt16kHz(recording)
        return (samples, Silence.isSilent(samples))
    }

    /// Opens System Settings at Sound, where the user picks the input device.
    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Installs the tap when access is granted and removes it when access is
    /// gone.
    private func syncTapWithAccess() {
        guard let tap else { return }
        let trusted = isTrusted()
        if trusted, !tap.isInstalled {
            if tap.start() {
                logger.info("Hotkey active")
            } else {
                // AXIsProcessTrusted may still say yes after access is gone.
                logger.notice("The system refused the keyboard tap")
            }
        } else if !trusted, tap.isInstalled {
            tap.stop()
            logger.info("Accessibility access is gone, keyboard tap removed")
        }
        publishTapState()
    }

    /// Tells the menu and the icon whether the tap is installed.
    private func publishTapState() {
        let installed = tap?.isInstalled ?? false
        if isHotkeyActive != installed {
            isHotkeyActive = installed
        }
    }

    /// The system switched the keyboard tap off, and the tap removed itself, see
    /// `HotkeyTap.handle(type:keyCode:flags:)`. The menu shows the talk key as off at
    /// once. After the same pause as after an access change, `syncTapWithAccess` installs
    /// a new tap, which the system refuses without access, even while AXIsProcessTrusted
    /// still says yes.
    private func tapWasSwitchedOff(_ reason: CGEventType) {
        let why = reason == .tapDisabledByTimeout ? "a timeout" : "user input"
        logger.notice("The system switched the keyboard tap off after \(why, privacy: .public), tap removed")
        publishTapState()
        scheduleAccessCheck()
    }

    /// Checks access again two seconds after the system reports a change to the
    /// Accessibility list.
    ///
    /// AXIsProcessTrusted answers from a cache inside Orra that only this
    /// notification clears, and System Settings posts the notification before
    /// it writes the change. That was read from the macOS 26.6 binaries and is
    /// not documented. Reading access right away, or polling, could therefore
    /// cache the old answer until the next change. For the same reason the tap
    /// does not ask when the system switches it off. Removing Orra from the list
    /// may not post the notification at all, so Orra may not notice it.
    private func watchAccess() {
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleAccessCheck()
            }
        }
    }

    private func scheduleAccessCheck() {
        accessCheckTask?.cancel()
        accessCheckTask = Task { [weak self, accessCheckDelay] in
            try? await Task.sleep(for: accessCheckDelay)
            guard !Task.isCancelled else { return }
            self?.syncTapWithAccess()
        }
    }
}
